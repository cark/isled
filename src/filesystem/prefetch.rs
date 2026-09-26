//! Ordered, bounded transfer of owned file contents to the cache's thread.
use super::{
    ProjectRoot,
    contents::{self, FileContents, ReadFailure},
    loaded::LoadedIssues,
};
use smallvec::SmallVec;
use std::{
    io,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    thread,
};

const BATCH_FILES: usize = 64;
const BATCH_BYTES: usize = 256 * 1024;
type ReadItem<'a> = (&'a str, Option<Result<FileContents, ReadFailure>>);
type Batch<'a> = SmallVec<[ReadItem<'a>; BATCH_FILES]>;

impl LoadedIssues {
    pub(super) fn visit_files<'n, E: From<io::Error>>(
        &self,
        root: &ProjectRoot,
        names: impl IntoIterator<Item = &'n str>,
        mut consume: impl FnMut(&str) -> Result<(), E>,
    ) -> Result<(), E> {
        let pending = names
            .into_iter()
            .map(|name| (name, self.contains(name.as_bytes())))
            .collect::<Vec<_>>();
        let cancellation = AtomicBool::new(false);
        thread::scope(|scope| {
            let (sender, receiver) = mpsc::sync_channel(2);
            let cancelled = &cancellation;
            let worker = thread::Builder::new()
                .name("issue-reader".into())
                .spawn_scoped(scope, move || {
                    send_batches(root, pending, sender, cancelled)
                })?;
            let mut failure = None;
            loop {
                let batch = receiver.recv();
                let Ok(batch) = batch else { break };
                for (name, contents) in batch {
                    if let Some(contents) = contents {
                        self.remember(name.as_bytes(), contents);
                    }
                    if failure.is_none()
                        && let Err(error) = consume(name)
                    {
                        failure = Some(error);
                        cancelled.store(true, Ordering::Relaxed);
                    }
                }
            }
            // Drain and retain already-read batches after failure, so a cache
            // corruption rebuild cannot reread them. Cancellation stops further
            // batches; receiving also unblocks a sender waiting on a full queue.
            drop(receiver);
            let joined = worker
                .join()
                .map_err(|_| io::Error::other("issue reader panicked"));
            failure.map_or(Ok(()), Err).and(joined.map_err(E::from))
        })
    }
}

fn send_batches<'a>(
    root: &ProjectRoot,
    pending: Vec<(&'a str, bool)>,
    sender: SyncSender<Batch<'a>>,
    cancelled: &AtomicBool,
) {
    let mut pending = pending.into_iter().peekable();
    while !cancelled.load(Ordering::Relaxed) && pending.peek().is_some() {
        let batch = read_batch(root, &mut pending);
        let sent = sender.send(batch);
        if sent.is_err() {
            break;
        }
    }
}

fn read_batch<'a>(
    root: &ProjectRoot,
    pending: &mut impl Iterator<Item = (&'a str, bool)>,
) -> Batch<'a> {
    let mut batch = Batch::new();
    let mut bytes = 0usize;
    for (name, cached) in pending.take(BATCH_FILES) {
        let contents = (!cached).then(|| contents::load(root, name.as_bytes()));
        if let Some(Ok(contents)) = &contents {
            bytes = bytes.saturating_add(contents.bytes.as_ref().map_or(0, Vec::len));
        }
        batch.push((name, contents));
        // One oversized file may exceed the byte target; file contents stay whole.
        if bytes >= BATCH_BYTES {
            break;
        }
    }
    batch
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture(count: usize, size: usize) -> (tempfile::TempDir, ProjectRoot, Vec<String>) {
        let temporary = tempfile::tempdir().unwrap();
        fs::create_dir(temporary.path().join(".issues")).unwrap();
        let names = (1..=count)
            .map(|id| format!("{id:04}-example.md"))
            .collect::<Vec<_>>();
        for name in &names {
            fs::write(
                temporary.path().join(".issues").join(name),
                vec![b'x'; size],
            )
            .unwrap();
        }
        let root = ProjectRoot::explicit(temporary.path()).unwrap();
        (temporary, root, names)
    }

    #[test]
    fn batches_respect_file_and_byte_targets_without_spilling() {
        for (count, size, expected) in [(BATCH_FILES + 1, 1, BATCH_FILES), (3, BATCH_BYTES, 1)] {
            let (_temporary, root, names) = fixture(count, size);
            let mut pending = names.iter().map(|name| (name.as_str(), false));
            let batch = read_batch(&root, &mut pending);
            assert_eq!(batch.len(), expected);
            assert!(!batch.spilled());
            assert_eq!(batch[0].0, names[0]);
            assert_eq!(pending.count(), count - expected);
        }
    }

    #[test]
    fn pipeline_keeps_order_and_reuses_successes_and_missing_failures() {
        let (_temporary, root, mut names) = fixture(BATCH_FILES * 3 + 1, 1);
        names.push("0999-missing.md".into());
        let loaded = LoadedIssues::default();
        let mut visited = Vec::new();
        loaded
            .visit_files(&root, names.iter().map(String::as_str), |name| {
                visited.push(name.to_owned());
                Ok::<_, io::Error>(())
            })
            .unwrap();
        assert_eq!(visited, names);
        assert_eq!(loaded.reads(), names.len() - 1);
        fs::write(root.issues_dir().join(&names[0]), b"changed").unwrap();
        fs::write(root.issues_dir().join("0999-missing.md"), b"now exists").unwrap();
        loaded
            .visit_files(&root, names.iter().map(String::as_str), |_| {
                Ok::<_, io::Error>(())
            })
            .unwrap();
        assert_eq!(loaded.reads(), names.len() - 1);
        assert_eq!(
            loaded
                .get(&root, names[0].as_bytes())
                .unwrap()
                .record()
                .unwrap()
                .bytes(),
            b"x"
        );
        assert!(loaded.get(&root, b"0999-missing.md").is_err());
    }

    #[test]
    fn consumer_failure_cancels_a_reader_with_more_than_a_queue_of_work() {
        let (_temporary, root, names) = fixture(BATCH_FILES * 5, 1);
        let loaded = LoadedIssues::default();
        let mut visits = 0;
        let error = loaded
            .visit_files(&root, names.iter().map(String::as_str), |_| {
                visits += 1;
                Err::<(), _>(io::Error::other("consumer failed"))
            })
            .unwrap_err();
        assert_eq!(error.to_string(), "consumer failed");
        assert_eq!(visits, 1);
        // Already-read batches are retained, but later batches are cancelled.
        assert!(loaded.reads() >= 1 && loaded.reads() < names.len());
    }
}
