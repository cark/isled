use super::error::AppError;
use super::issue_id::parse_issue_id;
use super::tag_input::parse_tag;
use isled::cli::TagCommand;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::issue::Tag;
use isled::mutation;

pub(crate) fn run(
    command: TagCommand,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let (arguments, adding) = match command {
        TagCommand::Add(arguments) => (arguments, true),
        TagCommand::Remove(arguments) => (arguments, false),
    };
    let id = parse_issue_id(&arguments.issue)?;
    let tags = parse_mutation_tags(arguments.tags, adding)?;
    let project = project()?;
    let lock = project.acquire_lock()?;
    let records = lock.read_issue_records(id)?;
    let plan = if adding {
        mutation::tag_add(&records, id, &tags)?
    } else {
        mutation::tag_remove(&records, id, &tags)?
    };
    lock.publish(&plan)?;
    lock.finish()?;
    let action = if adding { "added" } else { "removed" };
    Ok(format!(
        "{action} tags {} issue {id}\n",
        if adding { "to" } else { "from" }
    )
    .into_bytes())
}

fn parse_mutation_tags(
    values: Vec<String>,
    reject_conflicting: bool,
) -> Result<Vec<Tag>, AppError> {
    let mut tags = Vec::new();
    let mut priority: Option<Tag> = None;
    for value in values {
        let tag = parse_tag(&value)?;
        if reject_conflicting && tag.is_priority() {
            if priority.as_ref().is_some_and(|existing| existing != &tag) {
                return Err(AppError::Invocation(
                    "tag batch contains conflicting priorities".into(),
                ));
            }
            priority = Some(tag.clone());
        }
        if !tags.contains(&tag) {
            tags.push(tag);
        }
    }
    Ok(tags)
}
