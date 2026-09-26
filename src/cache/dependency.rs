//! Cached dependency traversal and the neighborhood needed by mutations.
use super::{
    Cache, CacheError,
    query::{dependency_node_from_summary, parse_cached_issue_id},
};
use crate::{
    issue::{IssueId, Status, WaitReason},
    query::dependency::{DependencyTree, Direction, Edge},
};
use std::collections::{BTreeMap, BTreeSet, btree_map::Entry};

impl Cache<'_> {
    pub fn adjacency(&self) -> Result<crate::wait_graph::Adjacency, CacheError> {
        let mut graph = crate::wait_graph::Adjacency::new();
        let mut statement = self.connection.prepare("SELECT waiting_issue_id,blocking_issue_id FROM dependencies ORDER BY waiting_issue_id,blocking_issue_id")?;
        for row in statement.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))? {
            let (source, target) = row?;
            graph
                .entry(parse_cached_issue_id(source)?)
                .or_default()
                .insert(parse_cached_issue_id(target)?);
        }
        Ok(graph)
    }
    pub fn title_participants(&self, id: IssueId) -> Result<BTreeSet<IssueId>, CacheError> {
        let mut ids = self.neighbors(id)?;
        ids.insert(id);
        // The requested record also carries mirrored neighbors not yet indexed
        // in an externally edited source's outgoing relationships.
        let name = self.filename(id)?;
        let loaded = self.lock.load_file(name.as_bytes())?;
        let record = loaded.record()?;
        let issue = record
            .issue()
            .map_err(|e| CacheError::Invalid(e.to_string()))?;
        ids.extend(issue.blocking().iter().map(|r| r.target));
        ids.extend(issue.waits().iter().map(|r| r.target));
        Ok(ids)
    }

    pub(super) fn neighbors(&self, id: IssueId) -> Result<BTreeSet<IssueId>, CacheError> {
        let mut query = self.connection.prepare(
            "SELECT blocking_issue_id FROM dependencies WHERE waiting_issue_id=?1
            UNION ALL SELECT waiting_issue_id FROM dependencies WHERE blocking_issue_id=?1
            UNION ALL SELECT target_id FROM relation_warnings WHERE source_id=?1
            UNION ALL SELECT source_id FROM relation_warnings WHERE target_id=?1",
        )?;
        query
            .query_map([id.get()], |r| r.get::<_, i64>(0))?
            .map(|r| parse_cached_issue_id(r?))
            .collect()
    }

    fn relations(
        &self,
        id: IssueId,
        direction: Direction,
    ) -> Result<Vec<(IssueId, WaitReason)>, CacheError> {
        let sql = match direction {
            Direction::Dependencies => {
                "SELECT blocking_issue_id,COALESCE(MAX(CASE WHEN owner_issue_id=waiting_issue_id THEN reason END),'Incomplete relation; reason not available.') FROM dependencies WHERE waiting_issue_id=?1 GROUP BY blocking_issue_id ORDER BY blocking_issue_id"
            }
            Direction::Dependents => {
                "SELECT waiting_issue_id,COALESCE(MAX(CASE WHEN owner_issue_id=waiting_issue_id THEN reason END),'Incomplete relation; reason not available.') FROM dependencies WHERE blocking_issue_id=?1 GROUP BY waiting_issue_id ORDER BY waiting_issue_id"
            }
        };
        let mut query = self.connection.prepare(sql)?;
        query
            .query_map([id.get()], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })?
            .map(|r| {
                let (id, reason) = r?;
                Ok((
                    parse_cached_issue_id(id)?,
                    WaitReason::parse(reason.as_bytes())
                        .map_err(|e| CacheError::Corrupt(e.to_string()))?,
                ))
            })
            .collect()
    }

    pub fn wait_show(&self, id: IssueId, with_path: bool) -> Result<Vec<u8>, CacheError> {
        self.summary(id)?;
        let mut bytes = Vec::new();
        for (direction, heading) in [
            (Direction::Dependencies, "Waits on:"),
            (Direction::Dependents, "Waited on by:"),
        ] {
            bytes.extend_from_slice(format!("{heading}\n").as_bytes());
            let relations = self.relations(id, direction)?;
            if relations.is_empty() {
                bytes.extend_from_slice(b"(none)\n");
            }
            for (neighbor, reason) in relations {
                let summary = self.summary(neighbor)?;
                let path = with_path
                    .then(|| self.root().issue_path_bytes(summary.filename().as_bytes()))
                    .transpose()?;
                bytes.extend_from_slice(&summary.render(path.as_deref()));
                bytes.extend_from_slice(b"  ");
                bytes.extend_from_slice(reason.as_bytes());
                bytes.push(b'\n');
            }
        }
        Ok(bytes)
    }

    pub fn dependency_tree(
        &self,
        root: IssueId,
        direction: Direction,
    ) -> Result<DependencyTree, CacheError> {
        let mut nodes = BTreeMap::new();
        let mut edges = BTreeMap::new();
        let first = self.summary(root)?;
        nodes.insert(root, dependency_node_from_summary(&first));
        let mut pending = vec![root];
        let mut expanded = BTreeSet::new();
        while let Some(id) = pending.pop() {
            if !expanded.insert(id) {
                continue;
            }
            for (neighbor, reason) in self.relations(id, direction)? {
                let source_open = nodes[&id].status == Status::Open;
                let neighbor_node = match nodes.entry(neighbor) {
                    Entry::Occupied(entry) => entry.into_mut(),
                    Entry::Vacant(entry) => {
                        entry.insert(dependency_node_from_summary(&self.summary(neighbor)?))
                    }
                };
                let blocking = source_open && neighbor_node.status == Status::Open;
                let (dependent, dependency) = match direction {
                    Direction::Dependencies => (id, neighbor),
                    Direction::Dependents => (neighbor, id),
                };
                edges.insert(
                    (dependent, dependency),
                    Edge {
                        dependent,
                        dependency,
                        reason: String::from_utf8(reason.as_bytes().to_vec())
                            .expect("parsed UTF-8 reason"),
                        blocking,
                    },
                );
                if blocking {
                    pending.push(neighbor);
                }
            }
        }
        Ok(DependencyTree::from_parts(root, direction, nodes, edges))
    }
}
