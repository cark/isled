use super::content_publication::publish_content;
use super::error::AppError;
use super::issue_id::parse_issue_id;
use super::statement_input::read_statement_stdin;
use isled::cli::{ContentTextArgs, StatementCommand};
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::mutation::{self, MutationError, StatementAction, StatementText};

pub(crate) fn run(
    arguments: isled::cli::StatementArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    match arguments.command {
        StatementCommand::Set(arguments) => apply_statement(arguments, StatementAction::Set, root),
        StatementCommand::Append(arguments) => {
            apply_statement(arguments, StatementAction::Append, root)
        }
        StatementCommand::Replace(arguments) => replace_statement(arguments, root),
    }
}

fn apply_inline_statement(
    arguments: ContentTextArgs,
    action: StatementAction,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.issue)?;
    let text = StatementText::try_parse(&arguments.text).map_err(|_| {
        AppError::Invocation("statement text must be one non-empty line without tabs".into())
    })?;
    let project = project()?;
    let lock = project.acquire_lock()?;
    let records = lock.read_issue_records(id)?;
    let plan = mutation::statement_mutate(&records, id, action, &text)?;
    publish_content(lock, &records, id, &plan)?;
    let verb = match action {
        StatementAction::Set => "set statement for",
        StatementAction::Append => "appended statement to",
    };
    Ok(format!("{verb} issue {id}\n").into_bytes())
}

fn apply_statement(
    arguments: isled::cli::StatementInputArgs,
    action: StatementAction,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    if let Some(text) = arguments.text {
        return apply_inline_statement(
            ContentTextArgs {
                issue: arguments.issue,
                text,
            },
            action,
            project,
        );
    }
    let id = parse_issue_id(&arguments.issue)?;
    let input = read_statement_stdin("Enter Statement text, then EOF (Ctrl-D).")?;
    let text = mutation::StdinStatementText::parse_stdin(&input).map_err(MutationError::from)?;
    let project = project()?;
    let lock = project.acquire_lock()?;
    let records = lock.read_issue_records(id)?;
    let plan = mutation::statement_mutate_stdin(&records, id, action, &text)?;
    publish_content(lock, &records, id, &plan)?;
    let verb = match action {
        StatementAction::Set => "set statement for",
        StatementAction::Append => "appended statement to",
    };
    Ok(format!("{verb} issue {id}\n").into_bytes())
}

fn replace_statement(
    arguments: isled::cli::StatementReplaceArgs,
    project: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.issue)?;
    let input = read_statement_stdin(&format!(
        "Enter old text, a line containing {}, then replacement text and EOF (Ctrl-D). Empty replacement deletes.",
        arguments.separator
    ))?;
    let replacement = mutation::StatementReplacement::parse_stdin(&input, &arguments.separator)
        .map_err(MutationError::from)?;
    let selection = if arguments.all {
        mutation::MatchSelection::All
    } else {
        arguments.occurrence.map_or(
            mutation::MatchSelection::Unique,
            mutation::MatchSelection::Occurrence,
        )
    };
    let project = project()?;
    let lock = project.acquire_lock()?;
    let records = lock.read_issue_records(id)?;
    let plan = mutation::statement_replace(&records, id, &replacement, selection)?;
    publish_content(lock, &records, id, &plan)?;
    Ok(format!("replaced statement text in issue {id}\n").into_bytes())
}
