//! Project one inspected Markdown source into cache rows.
use super::{Cache, CacheError};
use crate::{
    issue::{Issue, IssueId},
    record::parse_filename,
};
use rusqlite::params;
use std::{
    fs, io,
    time::{SystemTime, UNIX_EPOCH},
};

impl Cache<'_> {
    pub(super) fn refresh_file_rows(&mut self, name: &str) -> Result<(), CacheError> {
        self.last_neighbors.clear();
        let (id, _) =
            parse_filename(name.as_bytes()).map_err(|e| CacheError::Invalid(e.to_string()))?;
        self.warning_neighbors.extend(self.neighbors(id)?);
        self.inspected.insert(id, None);
        let loaded = match self.lock.load_file(name.as_bytes()) {
            Ok(loaded) => loaded,
            Err(crate::filesystem::FilesystemError::Io(error))
                if error.kind() == io::ErrorKind::NotFound =>
            {
                self.connection
                    .execute("DELETE FROM issues WHERE id=?1", [id.get()])?;
                return Ok(());
            }
            Err(error) => return self.record_unreadable_issue(id, name, &error.to_string()),
        };
        let record = match loaded.record() {
            Ok(record) => record,
            Err(error) => return self.record_unreadable_issue(id, name, &error.to_string()),
        };
        let metadata = match loaded.metadata {
            Ok(metadata) => metadata,
            Err(error) => return self.record_unreadable_issue(id, name, &error.to_string()),
        };
        if let Err(error) = record.issue() {
            return self.record_unreadable_issue(id, name, &error.to_string());
        }
        self.inspected.insert(id, Some(record));
        let issue = self.inspected[&id]
            .as_ref()
            .expect("just inserted record")
            .issue()
            .expect("just parsed record");
        self.last_neighbors
            .extend(issue.waits().iter().map(|r| r.target));
        self.last_neighbors
            .extend(issue.blocking().iter().map(|r| r.target));
        self.warning_neighbors
            .extend(self.last_neighbors.iter().copied());
        let modified = unix_timestamp_parts(metadata.modified().ok());
        let changed = change_time(&metadata);
        let fingerprint = self.inspected[&id]
            .as_ref()
            .expect("inspected valid record")
            .fingerprint()
            .cast_signed();
        if self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM issues WHERE id=?1 AND filename=?2 AND content_hash=?3 AND error IS NULL)",
            params![id.get(), name, fingerprint],
            |row| row.get::<_, bool>(0),
        )? {
            // Identical contents can still have new filesystem metadata.
            self.connection.execute(
                "UPDATE issues SET size=?2,modified_seconds=?3,modified_nanos=?4,changed_seconds=?5,changed_nanos=?6
                 WHERE id=?1 AND (size IS NOT ?2 OR modified_seconds IS NOT ?3 OR modified_nanos IS NOT ?4
                    OR changed_seconds IS NOT ?5 OR changed_nanos IS NOT ?6)",
                params![id.get(), i64::try_from(metadata.len()).ok(), modified.0, modified.1, changed.0, changed.1],
            )?;
            return Ok(());
        }
        self.connection
            .execute("DELETE FROM issues WHERE id=?1", [id.get()])?;
        self.connection.execute("INSERT INTO issues(id,filename,title,status,kind,created,size,
            modified_seconds,modified_nanos,changed_seconds,changed_nanos,content_hash) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
            params![id.get(), name, std::str::from_utf8(issue.title()).map_err(|e| CacheError::Invalid(e.to_string()))?,
                issue.status().as_str(),issue.kind().as_str(),issue.created().as_str(),
                i64::try_from(metadata.len()).ok(),modified.0,modified.1,changed.0,changed.1,fingerprint])?;
        self.write_tags(issue)?;
        self.write_dependencies(issue)
    }

    fn write_tags(&self, issue: &Issue) -> Result<(), CacheError> {
        for tag in issue.tags() {
            self.connection.execute(
                "INSERT INTO issue_tags VALUES(?1,?2)",
                params![issue.id().get(), tag.as_str()],
            )?;
        }
        Ok(())
    }

    fn write_dependencies(&self, issue: &Issue) -> Result<(), CacheError> {
        let waits = issue.waits().iter().map(|relation| {
            (
                issue.id(),
                relation.target,
                relation.reason.as_slice(),
                "INSERT INTO dependencies VALUES(?1,?2,?3,?4)",
            )
        });
        let blocking = issue.blocking().iter().map(|relation| {
            (
                relation.target,
                issue.id(),
                b"".as_slice(),
                "INSERT OR IGNORE INTO dependencies VALUES(?1,?2,?3,?4)",
            )
        });
        // Preserve authored ownership, outgoing reasons, and insertion order.
        for (waiting, blocker, reason, sql) in waits.chain(blocking) {
            self.connection.execute(
                sql,
                params![
                    issue.id().get(),
                    waiting.get(),
                    blocker.get(),
                    std::str::from_utf8(reason).map_err(|e| CacheError::Invalid(e.to_string()))?
                ],
            )?;
        }
        Ok(())
    }

    fn record_unreadable_issue(
        &self,
        id: IssueId,
        name: &str,
        error: &str,
    ) -> Result<(), CacheError> {
        self.connection
            .execute("DELETE FROM issues WHERE id=?1", [id.get()])?;
        self.connection.execute(
            "INSERT INTO issues(id,filename,error) VALUES(?1,?2,?3)",
            params![id.get(), name, error],
        )?;
        Ok(())
    }
}
pub(super) fn unix_timestamp_parts(value: Option<SystemTime>) -> (Option<i64>, Option<u32>) {
    let Some(value) = value else {
        return (None, None);
    };
    let pair = match value.duration_since(UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_secs())
            .ok()
            .map(|s| (s, d.subsec_nanos())),
        Err(e) => {
            let d = e.duration();
            i64::try_from(d.as_secs()).ok().and_then(|s| {
                if d.subsec_nanos() == 0 {
                    Some((-s, 0))
                } else {
                    s.checked_add(1)
                        .map(|s| (-s, 1_000_000_000 - d.subsec_nanos()))
                }
            })
        }
    };
    pair.map_or((None, None), |(s, n)| (Some(s), Some(n)))
}

#[cfg(unix)]
fn change_time(m: &fs::Metadata) -> (Option<i64>, Option<u32>) {
    use std::os::unix::fs::MetadataExt;
    (Some(m.ctime()), u32::try_from(m.ctime_nsec()).ok())
}
#[cfg(not(unix))]
fn change_time(_: &fs::Metadata) -> (Option<i64>, Option<u32>) {
    (None, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn timestamps_preserve_fractional_precision_on_both_sides_of_epoch() {
        assert_eq!(unix_timestamp_parts(None), (None, None));
        assert_eq!(unix_timestamp_parts(Some(UNIX_EPOCH)), (Some(0), Some(0)));
        assert_eq!(
            unix_timestamp_parts(Some(UNIX_EPOCH + Duration::new(2, 123))),
            (Some(2), Some(123))
        );
        assert_eq!(
            unix_timestamp_parts(Some(UNIX_EPOCH - Duration::new(2, 123))),
            (Some(-3), Some(999_999_877))
        );
        assert_eq!(
            unix_timestamp_parts(Some(UNIX_EPOCH - Duration::from_secs(2))),
            (Some(-2), Some(0))
        );
    }
}
