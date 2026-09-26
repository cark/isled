use super::CacheError;
use rusqlite::{CachedStatement, Connection, Params, Row};
use std::{fs, io, path::Path};

// Version 3 fixes the fingerprint interpretation to XXH3-64 on raw source bytes.
const VERSION: i64 = 5;

/// Owns SQLite lifecycle exceptions; data access always uses bounded statement reuse.
pub(super) struct Database {
    connection: Connection,
}

impl Database {
    pub(super) fn open(path: &Path) -> Result<(Self, bool), CacheError> {
        let (connection, fresh) = open_connection(path)?;
        Ok((Self { connection }, fresh))
    }

    pub(super) fn prepare(&self, sql: &str) -> rusqlite::Result<CachedStatement<'_>> {
        self.connection.prepare_cached(sql)
    }

    pub(super) fn execute<P: Params>(&self, sql: &str, params: P) -> rusqlite::Result<usize> {
        self.prepare(sql)?.execute(params)
    }

    pub(super) fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> rusqlite::Result<T>
    where
        P: Params,
        F: FnOnce(&Row<'_>) -> rusqlite::Result<T>,
    {
        self.prepare(sql)?.query_row(params, f)
    }

    pub(super) fn begin_immediate(&self) -> rusqlite::Result<()> {
        self.connection.execute_batch("BEGIN IMMEDIATE")
    }

    pub(super) fn commit(&self) -> rusqlite::Result<()> {
        self.connection.execute_batch("COMMIT")
    }

    pub(super) fn rollback(&self) -> rusqlite::Result<()> {
        self.connection.execute_batch("ROLLBACK")
    }
}

fn open_connection(path: &Path) -> Result<(Connection, bool), CacheError> {
    let connection = Connection::open(path)?;
    connection.busy_timeout(std::time::Duration::from_millis(250))?;
    let version =
        connection.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?;
    let fresh = version != VERSION;
    // Disposable derived data: avoid durable fsync latency on each refresh.
    // SQLite transactions still isolate normal readers; crash damage rebuilds.
    connection.execute_batch("PRAGMA foreign_keys = ON; PRAGMA synchronous = OFF;")?;
    if fresh {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
            DROP TABLE IF EXISTS issue_tags; DROP TABLE IF EXISTS dependencies;
            DROP TABLE IF EXISTS relation_warnings; DROP TABLE IF EXISTS issues; DROP TABLE IF EXISTS cache_state;",
        )?;
        connection.execute_batch(include_str!("schema.sql"))?;
        connection.execute_batch("COMMIT;")?;
    } else {
        validate_schema(&connection)?;
    }
    Ok((connection, fresh))
}

fn validate_schema(connection: &Connection) -> Result<(), CacheError> {
    for sql in [
        "SELECT directory_seconds,directory_nanos,diagnostics FROM cache_state LIMIT 0",
        "SELECT id,filename,title,status,kind,created,size,modified_seconds,modified_nanos,changed_seconds,changed_nanos,error,content_hash FROM issues LIMIT 0",
        "SELECT owner_issue_id,source_id,target_id,code,message,needs_reason FROM relation_warnings LIMIT 0",
        "SELECT issue_id,tag FROM issue_tags LIMIT 0",
        "SELECT owner_issue_id,waiting_issue_id,blocking_issue_id,reason FROM dependencies LIMIT 0",
    ] {
        connection
            .prepare(sql)
            .map_err(|e| CacheError::Corrupt(format!("unusable cache schema: {e}")))?;
    }
    Ok(())
}
pub(super) fn require_regular_file_if_present(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => Ok(()),
        Ok(_) => Err(io::Error::other(format!(
            "unsafe cache path: {}",
            path.display()
        ))),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::Database;
    use rusqlite::{Error, StatementStatus, named_params};

    #[test]
    fn row_queries_reuse_statements_without_retaining_bindings() {
        let directory = tempfile::tempdir().unwrap();
        let (database, _) = Database::open(&directory.path().join("cache.sqlite")).unwrap();
        let sql = "SELECT :value";
        assert_eq!(
            database
                .query_row(sql, named_params! {":value": "first"}, |row| {
                    row.get::<_, String>(0)
                })
                .unwrap(),
            "first"
        );
        let mut statement = database.prepare(sql).unwrap();
        // SQLite's run counter belongs to the prepared statement, not its SQL text.
        assert_eq!(statement.get_status(StatementStatus::Run), 1);
        assert_eq!(
            statement
                .query_row(&[] as &[(&str, &dyn rusqlite::ToSql)], |row| {
                    row.get::<_, Option<String>>(0)
                })
                .unwrap(),
            None
        );
        drop(statement);
        assert_eq!(
            database
                .prepare(sql)
                .unwrap()
                .get_status(StatementStatus::Run),
            2
        );
    }

    #[test]
    fn writes_remain_reusable_after_errors_and_rollback() {
        let directory = tempfile::tempdir().unwrap();
        let (database, _) = Database::open(&directory.path().join("cache.sqlite")).unwrap();
        let sql = "INSERT INTO issues(id, filename, error) VALUES(?1, ?2, ?3)";
        database.begin_immediate().unwrap();
        assert_eq!(
            database
                .execute(sql, (1, "first.md", "unreadable"))
                .unwrap(),
            1
        );
        assert!(
            database
                .execute(sql, (1, "duplicate.md", "unreadable"))
                .is_err()
        );
        database.rollback().unwrap();
        assert!(matches!(
            database.query_row("SELECT id FROM issues", [], |row| row.get::<_, i64>(0)),
            Err(Error::QueryReturnedNoRows)
        ));
        database.begin_immediate().unwrap();
        assert_eq!(
            database
                .execute(sql, (2, "second.md", "unreadable"))
                .unwrap(),
            1
        );
        database.commit().unwrap();
        assert_eq!(
            database
                .prepare(sql)
                .unwrap()
                .get_status(StatementStatus::Run),
            3
        );
        let mut statement = database.prepare("SELECT id, filename FROM issues").unwrap();
        let mut rows = statement.query([]).unwrap();
        let row = rows.next().unwrap().unwrap();
        assert_eq!(row.get::<_, i64>(0).unwrap(), 2);
        assert_eq!(row.get_ref(1).unwrap().as_str().unwrap(), "second.md");
        assert!(rows.next().unwrap().is_none());
    }
}
