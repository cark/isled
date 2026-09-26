//! Bounded, disposable candidate cache, serialized by the existing ledger lock.
use super::{Direction, Graph, Plan, VERSION, plan::PlanData};
use crate::{filesystem::StoreLock, issue::Status};
use serde::Serialize;
use std::{
    error::Error,
    fs,
    io::{self, Read, Write},
    path::Path,
};
use xxhash_rust::xxh3::xxh3_64;

const MAGIC: &[u8; 8] = b"IGRAPH01";

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize)]
pub enum Reuse {
    Hit,
    Miss,
    RebuiltInvalid,
    Oversized,
}

pub struct CachedPlan {
    pub plan: Plan,
    pub reuse: Reuse,
    pub stored_bytes: usize,
}

#[derive(Serialize)]
struct Key<'a> {
    version: u32,
    ledger: &'a [u8],
    status: Option<&'static str>,
    direction: Direction,
    graph: &'a Graph,
}

/// Six slots (status × direction), plus one bounded staging file under this lock.
/// Caller supplies a candidate storage budget; no production default is implied.
pub fn load_or_compute(
    lock: &StoreLock<'_>,
    graph: &Graph,
    status: Option<Status>,
    direction: Direction,
    max_bytes: usize,
) -> Result<CachedPlan, Box<dyn Error>> {
    let directory = lock.root().issues_dir().join(".cache");
    ensure_directory(&directory)?;
    let directory = directory.join("graph-layout-candidate");
    ensure_directory(&directory)?;
    // The caller can lower its budget between requests; retain no larger old slot.
    for selection in ["open", "closed", "all"] {
        for orientation in ["prerequisites", "dependents"] {
            let slot = directory.join(format!("{selection}-{orientation}.plan"));
            if require_regular_if_present(&slot)? && fs::metadata(&slot)?.len() > max_bytes as u64 {
                fs::remove_file(slot)?;
            }
        }
    }
    remove_regular_if_present(&directory.join("pending.plan"))?;
    let key = serde_json::to_vec(&Key {
        version: VERSION,
        ledger: lock.root().path_bytes_lossless()?,
        status: status.map(Status::as_str),
        direction,
        graph,
    })?;
    let name = format!(
        "{}-{}.plan",
        status.map_or("all", Status::as_str),
        match direction {
            Direction::PrerequisitesFirst => "prerequisites",
            Direction::DependentsFirst => "dependents",
        }
    );
    let path = directory.join(name);
    let mut reuse = Reuse::Miss;
    if let Some(bytes) = read_bounded(&path, max_bytes)? {
        match decode(&bytes, &key, graph, direction) {
            Ok(Some(plan)) => {
                return Ok(CachedPlan {
                    plan,
                    reuse: Reuse::Hit,
                    stored_bytes: bytes.len(),
                });
            }
            Ok(None) => {}
            Err(()) => reuse = Reuse::RebuiltInvalid,
        }
    }
    let plan = graph.layout(direction)?;
    let mut bytes = LimitedBuffer {
        bytes: Vec::new(),
        limit: max_bytes,
    };
    let encoded = (|| -> io::Result<()> {
        bytes.write_all(MAGIC)?;
        bytes.write_all(&(key.len() as u64).to_le_bytes())?;
        bytes.write_all(&[0; 8])?;
        bytes.write_all(&key)?;
        serde_json::to_writer(&mut bytes, &plan.data).map_err(io::Error::other)
    })();
    if encoded.is_err() {
        // An obsolete oversized slot must not remain outside today's budget.
        remove_regular_if_present(&path)?;
        return Ok(CachedPlan {
            plan,
            reuse: Reuse::Oversized,
            stored_bytes: 0,
        });
    }
    let checksum = xxh3_64(&bytes.bytes[24..]);
    bytes.bytes[16..24].copy_from_slice(&checksum.to_le_bytes());
    let staging = directory.join("pending.plan");
    // Only this ledger's held lock can reach these slots.
    let result = (|| -> io::Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staging)?;
        file.write_all(&bytes.bytes)?;
        drop(file);
        require_regular_if_present(&path)?;
        fs::rename(&staging, &path)
    })();
    if result.is_err() {
        // Preserve publication errors even if staging cleanup also fails.
        let _ = fs::remove_file(&staging);
    }
    result?;
    Ok(CachedPlan {
        plan,
        reuse,
        stored_bytes: bytes.bytes.len(),
    })
}

fn decode(
    bytes: &[u8],
    key: &[u8],
    graph: &Graph,
    direction: Direction,
) -> Result<Option<Plan>, ()> {
    if bytes.len() < 24 || &bytes[..8] != MAGIC {
        return Err(());
    }
    let length = usize::try_from(u64::from_le_bytes(bytes[8..16].try_into().map_err(|_| ())?))
        .map_err(|_| ())?;
    let end = 24_usize.checked_add(length).ok_or(())?;
    let stored_key = bytes.get(24..end).ok_or(())?;
    let checksum = u64::from_le_bytes(bytes[16..24].try_into().map_err(|_| ())?);
    if xxh3_64(&bytes[24..]) != checksum {
        return Err(());
    }
    if stored_key != key {
        return Ok(None);
    }
    let data: PlanData = serde_json::from_slice(&bytes[end..]).map_err(|_| ())?;
    Plan::decode(data, graph, direction)
        .map(Some)
        .map_err(|_| ())
}

fn read_bounded(path: &Path, limit: usize) -> io::Result<Option<Vec<u8>>> {
    if !require_regular_if_present(path)? {
        return Ok(None);
    }
    let file = fs::File::open(path)?;
    if file.metadata()?.len() > limit as u64 {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    file.take((limit as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    Ok((bytes.len() <= limit).then_some(bytes))
}

fn ensure_directory(path: &Path) -> io::Result<()> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    if !fs::symlink_metadata(path)?.file_type().is_dir() {
        return Err(io::Error::other(
            "candidate layout cache path is not a regular directory",
        ));
    }
    Ok(())
}

fn require_regular_if_present(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_file() => Ok(true),
        Ok(_) => Err(io::Error::other(
            "candidate layout cache entry is not a regular file",
        )),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

fn remove_regular_if_present(path: &Path) -> io::Result<()> {
    if require_regular_if_present(path)? {
        fs::remove_file(path)?;
    }
    Ok(())
}

struct LimitedBuffer {
    bytes: Vec<u8>,
    limit: usize,
}

impl Write for LimitedBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            return Err(io::Error::other(
                "candidate layout cache byte budget exceeded",
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests;
