PRAGMA user_version = 5;
CREATE TABLE cache_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    directory_seconds INTEGER,
    directory_nanos INTEGER,
    diagnostics TEXT NOT NULL DEFAULT '[]'
);
INSERT INTO cache_state(singleton) VALUES(1);
CREATE TABLE issues (
    id INTEGER PRIMARY KEY CHECK(id BETWEEN 1 AND 9999),
    filename TEXT NOT NULL UNIQUE,
    title TEXT, status TEXT, kind TEXT, created TEXT,
    size INTEGER, modified_seconds INTEGER, modified_nanos INTEGER,
    changed_seconds INTEGER, changed_nanos INTEGER,
    error TEXT,
    content_hash INTEGER,
    CHECK(error IS NOT NULL OR
        (title IS NOT NULL AND status IN ('open','closed') AND kind IS NOT NULL AND created IS NOT NULL))
);
CREATE INDEX issues_status ON issues(status, id);
CREATE INDEX issues_errors ON issues(id) WHERE error IS NOT NULL;
CREATE TABLE issue_tags (
    issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    tag TEXT NOT NULL,
    PRIMARY KEY(issue_id, tag)
);
CREATE INDEX tags_by_tag ON issue_tags(tag, issue_id);
CREATE TABLE dependencies (
    owner_issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    waiting_issue_id INTEGER NOT NULL CHECK(waiting_issue_id BETWEEN 1 AND 9999),
    blocking_issue_id INTEGER NOT NULL CHECK(blocking_issue_id BETWEEN 1 AND 9999),
    reason TEXT NOT NULL,
    PRIMARY KEY(owner_issue_id, waiting_issue_id, blocking_issue_id)
);
CREATE INDEX dependencies_by_blocker ON dependencies(blocking_issue_id, waiting_issue_id);
CREATE INDEX dependencies_by_waiter ON dependencies(waiting_issue_id, blocking_issue_id);

CREATE TABLE relation_warnings (
    owner_issue_id INTEGER NOT NULL CHECK(owner_issue_id BETWEEN 1 AND 9999),
    source_id INTEGER NOT NULL CHECK(source_id BETWEEN 1 AND 9999),
    target_id INTEGER NOT NULL CHECK(target_id BETWEEN 1 AND 9999),
    code TEXT NOT NULL,
    message TEXT NOT NULL,
    needs_reason INTEGER NOT NULL CHECK(needs_reason IN (0,1)),
    PRIMARY KEY(owner_issue_id, source_id, target_id, code)
);
CREATE INDEX relation_warnings_source ON relation_warnings(source_id, target_id);
CREATE INDEX relation_warnings_target ON relation_warnings(target_id, source_id);
