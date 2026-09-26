//! Ordered human batch output, with independent issue diagnostics and one lock.
use crate::commands::error::AppError;
use isled::{
    cache::{Cache, ShownIssue},
    diagnostic::RelationWarning,
    filesystem::ProjectRoot,
    issue::IssueId,
};
use std::{
    collections::BTreeMap,
    io::{self, Write},
};

pub(super) fn run(project: &ProjectRoot, ids: &[IssueId]) -> Result<Vec<u8>, AppError> {
    let lock = project.acquire_lock()?;
    let selected = ids.iter().copied().collect();
    let mut cache = Cache::open(&lock)?;
    let mut result = cache.show_batch(&selected);
    if matches!(&result, Err(error) if error.is_corruption()) {
        eprintln!("isled: warning: corrupt cache discovered during query; rebuilding once");
        drop(cache);
        cache = Cache::rebuild(&lock)?;
        result = cache.show_batch(&selected);
    }
    // Per-record results replace metadata-query omissions and unscoped relation
    // hints. Cache maintenance failures still concern the whole command.
    for warning in cache.maintenance_warnings() {
        eprintln!("isled: warning: {warning}");
    }
    drop(cache);
    lock.finish()?;
    let issues = result?;
    let failed = write_batch(
        ids,
        &issues,
        &mut io::stdout().lock(),
        &mut io::stderr().lock(),
    )?;
    if failed {
        Err(AppError::ShowFailures)
    } else {
        Ok(Vec::new())
    }
}

fn write_batch(
    ids: &[IssueId],
    issues: &BTreeMap<IssueId, ShownIssue>,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> Result<bool, AppError> {
    let mut failed = false;
    let mut needs_newline = false;
    for id in ids {
        let issue = &issues[id];
        match issue.content() {
            Ok(record) => {
                if needs_newline {
                    stdout.write_all(b"\n").map_err(AppError::Io)?;
                }
                stdout.write_all(record.bytes()).map_err(AppError::Io)?;
                needs_newline = !record.bytes().ends_with(b"\n");
                if !issue.warnings().is_empty() {
                    stdout.flush().map_err(AppError::Io)?;
                }
                write_warnings(*id, issue.warnings(), stderr)?;
            }
            Err(error) => {
                stdout.flush().map_err(AppError::Io)?;
                writeln!(stderr, "isled: issue #{id}: error: {error}").map_err(AppError::Io)?;
                failed = true;
            }
        }
    }
    stdout.flush().map_err(AppError::Io)?;
    Ok(failed)
}

fn write_warnings(
    id: IssueId,
    warnings: &[RelationWarning],
    stderr: &mut impl Write,
) -> Result<(), AppError> {
    for warning in warnings {
        writeln!(
            stderr,
            "isled: issue #{id}: warning [{}]: {}",
            warning.code(),
            warning.message()
        )
        .map_err(AppError::Io)?;
    }
    Ok(())
}
