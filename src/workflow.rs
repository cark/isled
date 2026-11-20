//! Ledger-local workflow definitions and their built-in defaults.
use crate::filesystem::ProjectRoot;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Write},
};

const DEFAULT: &str = include_str!("workflow-default.toml");

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Workflow {
    pub states: BTreeMap<String, State>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct State {
    pub label: String,
    pub clock: Clock,
    #[serde(default)]
    pub reasons: BTreeMap<String, Reason>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Clock {
    Off,
    Manual,
    Auto,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Reason {
    pub label: String,
    pub prompt: Option<String>,
}

pub(crate) fn id(value: &str) -> bool {
    value.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && value.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        })
}

fn line(value: &str) -> bool {
    !value.trim().is_empty()
        && value.trim() == value
        && !value.contains('|')
        && !value.chars().any(char::is_control)
}

impl Workflow {
    pub fn read(project: &ProjectRoot) -> io::Result<(Self, String)> {
        let path = project.issues_dir().join("workflow.toml");
        let source = match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_file() => fs::read_to_string(&path)?,
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "workflow.toml must be a regular file",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => DEFAULT.to_owned(),
            Err(error) => return Err(error),
        };
        let invalid = |msg: String| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("{}: {msg}", path.display()),
            )
        };
        let workflow: Self = toml::from_str(&source).map_err(|e| invalid(e.to_string()))?;
        for (key, state) in &workflow.states {
            if key == "not-queued" || !id(key) || !line(&state.label) {
                return Err(invalid(format!("invalid state ID or label for {key:?}")));
            }
            for (reason, definition) in &state.reasons {
                if !id(reason)
                    || !line(&definition.label)
                    || definition.prompt.as_ref().is_some_and(|s| !line(s))
                {
                    return Err(invalid(format!(
                        "invalid reason definition for {key}.{reason}"
                    )));
                }
            }
        }
        Ok((workflow, source))
    }

    pub fn init(project: &ProjectRoot) -> io::Result<()> {
        let directory = project.issues_dir();
        let mut file = tempfile::NamedTempFile::new_in(&directory)?;
        file.write_all(DEFAULT.as_bytes())?;
        file.persist_noclobber(directory.join("workflow.toml"))?;
        Ok(())
    }
}

impl Workflow {
    pub fn state(&self, id: &str) -> Result<&State, String> {
        self.states
            .get(id)
            .ok_or_else(|| format!("unknown work state: {id}"))
    }

    pub fn validate_filters(&self, filters: &crate::query::Filters) -> Result<(), String> {
        let state = filters.work_state.as_ref().map(|s| s.as_str());
        if let Some(id) = state.filter(|id| *id != "not-queued") {
            self.state(id)?;
        }
        if let Some(reason) = &filters.work_reason {
            let id = reason.as_str();
            if !self.states.values().any(|s| s.reasons.contains_key(id)) {
                return Err(format!("unknown work reason: {id}"));
            }
        }
        Ok(())
    }
    pub fn label<'a>(&'a self, state: &'a str, reason: Option<&'a str>) -> &'a str {
        if state == "not-queued" {
            return "";
        }
        let definition = self.states.get(state);
        match reason {
            Some(id) => definition
                .and_then(|s| s.reasons.get(id))
                .map_or(id, |r| &r.label),
            None => definition.map_or(state, |s| &s.label),
        }
    }
}
