//! Validated completion choices from cached metadata and provisional criteria.
use super::{Cache, CacheError};
use crate::{
    issue::{Name, Status, Tag},
    query::{Filters, SearchSnippets},
};
use std::collections::BTreeSet;

impl Cache<'_> {
    pub(crate) fn frontend_choices(&self) -> Result<Vec<String>, CacheError> {
        let mut choices = vec!["s:open".into(), "s:closed".into()];
        choices.extend(
            ["not-queued", "queued", "in-progress", "awaiting-owner"]
                .map(|state| format!("w:{state}")),
        );
        choices.extend(["r:review".into(), "r:clarification".into()]);
        self.append_tag_choices(&mut choices)?;
        self.append_kind_choices(&mut choices)?;
        Ok(choices)
    }

    pub(crate) fn contextual_choices(
        &self,
        filters: &Filters,
        kinds: &[Name],
        text: Option<&SearchSnippets>,
    ) -> Result<Vec<String>, CacheError> {
        // Finish the established tag-before-kind validation even when no candidate
        // matches. Do not turn corruption into an apparently empty choice set.
        let tags = self.choice_tags()?;
        let mut validated_kinds = Vec::new();
        self.append_kind_choices(&mut validated_kinds)?;
        let unrestricted_status = Filters {
            status: None,
            ..filters.clone()
        };
        let rows = self.filter_summaries(&unrestricted_status, kinds, text)?;
        let mut choices = Vec::new();
        for (status, choice) in [(Status::Open, "s:open"), (Status::Closed, "s:closed")] {
            if rows.iter().any(|row| row.status() == status) {
                choices.push(choice.into());
            }
        }
        let work_rows = if filters.work_state.is_some() {
            self.filter_summaries(
                &Filters {
                    work_state: None,
                    ..filters.clone()
                },
                kinds,
                text,
            )?
        } else {
            Vec::new()
        };
        let work_rows = if filters.work_state.is_some() {
            &work_rows
        } else {
            &rows
        };
        for state in ["not-queued", "queued", "in-progress", "awaiting-owner"] {
            if work_rows.iter().any(|row| {
                row.work().state == state
                    && filters.status.is_none_or(|status| row.status() == status)
            }) {
                choices.push(format!("w:{state}"));
            }
        }
        let reason_rows = if filters.work_reason.is_some() {
            self.filter_summaries(
                &Filters {
                    work_reason: None,
                    ..filters.clone()
                },
                kinds,
                text,
            )?
        } else {
            Vec::new()
        };
        let reason_rows = if filters.work_reason.is_some() {
            &reason_rows
        } else {
            &rows
        };
        for reason in ["review", "clarification"] {
            if reason_rows.iter().any(|row| {
                row.work().reason == Some(reason)
                    && filters.status.is_none_or(|status| row.status() == status)
            }) {
                choices.push(format!("r:{reason}"));
            }
        }
        let selected = rows
            .iter()
            .filter(|row| filters.status.is_none_or(|status| row.status() == status));
        let ids = selected
            .clone()
            .map(|row| row.id().get())
            .collect::<BTreeSet<_>>();
        let selected_tags = tags
            .iter()
            .filter(|(id, _)| ids.contains(id))
            .map(|(_, tag)| tag)
            .collect::<BTreeSet<_>>();
        choices.extend(selected_tags.into_iter().map(|tag| format!("t:{tag}")));
        let selected_kinds = selected.map(|row| row.kind()).collect::<BTreeSet<_>>();
        choices.extend(selected_kinds.into_iter().map(|kind| format!("k:{kind}")));
        Ok(choices)
    }

    fn choice_tags(&self) -> Result<Vec<(u16, Tag)>, CacheError> {
        let mut query = self
            .connection
            .prepare("SELECT issue_id,tag FROM issue_tags ORDER BY tag,issue_id")?;
        query
            .query_map([], |row| {
                Ok((row.get::<_, u16>(0)?, row.get::<_, String>(1)?))
            })?
            .map(|row| {
                let (id, value) = row?;
                let tag = Tag::try_parse(value.as_bytes())
                    .map_err(|error| CacheError::Corrupt(error.to_string()))?;
                Ok((id, tag))
            })
            .collect()
    }

    fn append_tag_choices(&self, choices: &mut Vec<String>) -> Result<(), CacheError> {
        let mut query = self
            .connection
            .prepare("SELECT DISTINCT tag FROM issue_tags ORDER BY tag")?;
        let tags = query.query_map([], |row| row.get::<_, String>(0))?;
        for tag in tags {
            let tag = Tag::try_parse(tag?.as_bytes())
                .map_err(|error| CacheError::Corrupt(error.to_string()))?;
            choices.push(format!("t:{tag}"));
        }
        Ok(())
    }

    fn append_kind_choices(&self, choices: &mut Vec<String>) -> Result<(), CacheError> {
        let mut query = self
            .connection
            .prepare("SELECT DISTINCT kind FROM issues WHERE error IS NULL ORDER BY kind")?;
        let kinds = query.query_map([], |row| row.get::<_, String>(0))?;
        for kind in kinds {
            let kind = Name::try_parse(kind?.as_bytes())
                .map_err(|error| CacheError::Corrupt(error.to_string()))?;
            choices.push(format!("k:{kind}"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filesystem::{ProjectRoot, initialize_ledger};

    #[test]
    fn corrupt_tag_is_reported_before_kind_and_later_values_are_validated() {
        let directory = tempfile::tempdir().unwrap();
        initialize_ledger(directory.path()).unwrap();
        let root = ProjectRoot::discover(directory.path()).unwrap();
        let lock = root.acquire_lock().unwrap();
        let cache = Cache::open(&lock).unwrap();
        cache.connection.execute(
            "INSERT INTO issues(id,filename,title,status,kind,created) VALUES(1,'0001-test.md','Test','open','z-invalid-','2026-09-05')",
            [],
        ).unwrap();
        for tag in ["aaa", "priority-unknown"] {
            cache
                .connection
                .execute("INSERT INTO issue_tags(issue_id,tag) VALUES(1,?1)", [tag])
                .unwrap();
        }
        assert!(
            matches!(cache.frontend_choices(), Err(CacheError::Corrupt(message))
            if message == "invalid lowercase hyphenated tag")
        );
        assert!(
            matches!(cache.contextual_choices(&Filters::default(), &[], None),
            Err(CacheError::Corrupt(message)) if message == "invalid lowercase hyphenated tag")
        );
        cache
            .connection
            .execute("DELETE FROM issue_tags WHERE tag='priority-unknown'", [])
            .unwrap();
        assert!(
            matches!(cache.frontend_choices(), Err(CacheError::Corrupt(message))
            if message == "name must be lowercase ASCII words separated by hyphens")
        );
        assert!(
            matches!(cache.contextual_choices(&Filters::default(), &[], None),
            Err(CacheError::Corrupt(message))
            if message == "name must be lowercase ASCII words separated by hyphens")
        );
    }
}
