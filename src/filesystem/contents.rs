//! Complete content reads using an already obtained size as an allocation hint.
use super::ProjectRoot;
use std::{
    fs,
    io::{self, Read},
};

pub(super) struct FileContents {
    pub(super) metadata: fs::Metadata,
    pub(super) bytes: io::Result<Vec<u8>>,
}

pub(super) enum ReadFailure {
    Unsafe,
    Io(io::Error),
}

impl From<io::Error> for ReadFailure {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub(super) fn load(root: &ProjectRoot, filename: &[u8]) -> Result<FileContents, ReadFailure> {
    let path = root
        .issues_dir()
        .join(std::str::from_utf8(filename).expect("checked filename"));
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(ReadFailure::Unsafe);
    }
    let bytes = fs::File::open(path).and_then(|file| read_contents(file, metadata.len()));
    Ok(FileContents { metadata, bytes })
}

pub(super) fn read_contents(reader: impl Read, size: u64) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(usize::try_from(size).unwrap_or(usize::MAX))?;
    // File::read_to_end fetches metadata again. Take uses the generic reader,
    // retaining std's short-read, Interrupted, and EOF handling. Its maximum
    // limit does not truncate growing files to the earlier metadata length.
    reader.take(u64::MAX).read_to_end(&mut bytes)?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_size_hints_do_not_truncate_or_require_missing_bytes() {
        for length in [0, 1, 31, 32, 8192, 100_000] {
            let bytes = vec![b'x'; length];
            for hint in [0, length / 2, length, length + 100] {
                assert_eq!(read_contents(bytes.as_slice(), hint as u64).unwrap(), bytes);
            }
        }
    }

    struct Fragmented<'a> {
        bytes: &'a [u8],
        interrupted: bool,
        fail_at_end: bool,
    }

    impl Read for Fragmented<'_> {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            self.interrupted = !self.interrupted;
            if self.interrupted {
                return Err(io::ErrorKind::Interrupted.into());
            }
            if self.bytes.is_empty() && self.fail_at_end {
                return Err(io::ErrorKind::PermissionDenied.into());
            }
            let count = output.len().min(self.bytes.len()).min(3);
            output[..count].copy_from_slice(&self.bytes[..count]);
            self.bytes = &self.bytes[count..];
            Ok(count)
        }
    }

    #[test]
    fn interrupted_and_short_reads_continue_but_other_errors_propagate() {
        let bytes = b"complete contents with multiple short reads";
        for fail_at_end in [false, true] {
            let result = read_contents(
                Fragmented {
                    bytes,
                    interrupted: false,
                    fail_at_end,
                },
                bytes.len() as u64,
            );
            if fail_at_end {
                assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
            } else {
                assert_eq!(result.unwrap(), bytes);
            }
        }
    }
}
