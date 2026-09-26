//! One stdin request for a compact view or a targeted batch of issue details.
use super::{cached_read::with_locked_query_mode, error::AppError};
use isled::{
    filesystem::{FilesystemError, ProjectRoot},
    frontend::{
        self,
        request::{Mode, Request},
    },
};
use std::io::{self, Read};

pub(crate) fn run(
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes).map_err(AppError::Io)?;
    let request = Request::parse(&bytes).map_err(AppError::Invocation)?;
    let project = root()?;
    let lock = project.acquire_lock()?;
    // Full views retain the existing strict identity and path boundary.
    if request.mode() != Mode::Details {
        lock.read_identities()?;
    }
    let output = with_locked_query_mode(&lock, request.mode() == Mode::Refresh, |cache| {
        Ok(frontend::respond(cache, &request)?)
    });
    lock.finish()?;
    output
}
