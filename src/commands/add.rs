use super::error::AppError;
use super::statement_input::read_statement_stdin;
use super::tag_input::parse_tag;
use chrono::Local;
use isled::cli::AddArgs;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::issue::{CreatedDate, Name, Tag};
use isled::mutation::{self, AddStatementText, MutationError, TitleText};

pub(crate) fn run(
    arguments: AddArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let kind_value = arguments
        .kind
        .last()
        .ok_or_else(|| AppError::Invocation("add requires a lowercase hyphenated --kind".into()))?;
    let kind = Name::try_parse(kind_value.as_bytes())
        .map_err(|_| AppError::Invocation("add requires a lowercase hyphenated --kind".into()))?;
    let title = TitleText::parse(&arguments.title)
        .map_err(|error| AppError::Invocation(error.to_string()))?;
    let statement = if let Some(text) = arguments.statement {
        AddStatementText::parse(&text).map_err(|error| AppError::Invocation(error.to_string()))?
    } else {
        let input = read_statement_stdin(
            "Enter Statement text, then EOF (Ctrl-D). Use ### or deeper for subsections.",
        )?;
        AddStatementText::parse_stdin(&input).map_err(MutationError::from)?
    };
    let slug = arguments
        .slug
        .last()
        .map(|value| {
            Name::try_parse(value.as_bytes())
                .map_err(|_| AppError::Invocation(format!("invalid slug: {value}")))
        })
        .transpose()?
        .unwrap_or_else(|| mutation::derive_slug(title.as_str()));
    let tags = parse_add_tags(arguments.tag)?;

    let project = project()?;
    if arguments.with_path {
        project.ensure_tsv_output_path()?;
    }
    let lock = project.acquire_lock()?;
    let id = lock.next_available_id()?;
    let created_text = Local::now().format("%Y-%m-%d").to_string();
    let created = CreatedDate::try_parse(created_text.as_bytes())
        .expect("chrono formats a valid YYYY-MM-DD shaped date");
    let replacement =
        mutation::add_record_validated(id, &slug, &kind, &title, &statement, &created, &tags);
    let path = arguments
        .with_path
        .then(|| project.issue_path_bytes(replacement.filename()))
        .transpose()?;
    lock.add(&replacement)?;
    lock.finish()?;
    if let Some(path) = path {
        let mut output = format!("{id}\t").into_bytes();
        output.extend_from_slice(&path);
        output.push(b'\n');
        Ok(output)
    } else {
        Ok(format!("{id}\n").into_bytes())
    }
}

fn parse_add_tags(values: Vec<String>) -> Result<Vec<Tag>, AppError> {
    let mut tags = Vec::new();
    let mut priority: Option<Tag> = None;
    for value in values {
        let tag = parse_tag(&value)?;
        if tag.is_priority() {
            if priority.as_ref().is_some_and(|existing| existing != &tag) {
                return Err(AppError::Invocation(
                    "add cannot contain conflicting priorities".into(),
                ));
            }
            priority = Some(tag.clone());
        }
        if tags.contains(&tag) {
            return Err(AppError::Invocation(format!("duplicate tag: {value}")));
        }
        tags.push(tag);
    }
    Ok(tags)
}
