mod commands;

use commands::error::AppError;
use isled::cli::{Cli, Command, OutcomeCommand, TitleCommand};
use isled::filesystem::{CacheCleanup, FilesystemError, ProjectRoot};
use std::io::{self, Write};

fn main() {
    if let Some(topic) = isled::cli::missing_command_topic(std::env::args_os().skip(1)) {
        match isled::cli::render_help(&topic) {
            Ok(output) => {
                let _ = io::stdout().write_all(&output);
                std::process::exit(1);
            }
            Err(error) => {
                let _ = error.print();
                std::process::exit(1);
            }
        }
    }
    let cli = match isled::cli::parse() {
        Ok(cli) => cli,
        Err(error) => {
            let success = matches!(
                error.kind(),
                clap::error::ErrorKind::DisplayHelp | clap::error::ErrorKind::DisplayVersion
            );
            let _ = error.print();
            std::process::exit(if success { 0 } else { 1 });
        }
    };

    match run(cli) {
        Ok(output) => {
            if let Err(error) = io::stdout().write_all(&output) {
                fail(&AppError::Io(error));
            }
        }
        Err(AppError::CheckFindings(output)) => {
            if let Err(error) = io::stdout().write_all(&output) {
                fail(&AppError::Io(error));
            }
            std::process::exit(1);
        }
        Err(AppError::ShowFailures) => std::process::exit(1),
        Err(error) => fail(&error),
    }
}

fn fail(error: &AppError) -> ! {
    eprintln!("isled: {error}");
    std::process::exit(if matches!(error, AppError::CheckOperational(_)) {
        2
    } else {
        1
    })
}

fn run(cli: Cli) -> Result<Vec<u8>, AppError> {
    let root = || {
        let root = match cli.root.last() {
            Some(path) => ProjectRoot::explicit(path),
            None => ProjectRoot::discover(&std::env::current_dir().map_err(FilesystemError::Io)?),
        }?;
        Ok(root.with_cache_cleanup(CacheCleanup::LeaveToProcessExit))
    };

    match cli.command {
        Command::Install(_) | Command::Installation(_) if !cli.root.is_empty() => {
            Err(AppError::Invocation(
                "Use --directory for installation; --root selects an issue ledger".into(),
            ))
        }
        Command::Install(arguments) => isled::installation::install(arguments.directory.as_deref())
            .and_then(|result| result.output(arguments.json))
            .map_err(AppError::Io),
        Command::Installation(arguments) => {
            isled::installation::inspect(arguments.directory.as_deref())
                .and_then(|result| result.output(arguments.json))
                .map_err(AppError::Io)
        }
        Command::Init => commands::init::run(cli.root),
        Command::Add(arguments) => commands::add::run(arguments, root),
        Command::Cache(arguments) => commands::cache_refresh::run(arguments, root),
        Command::List(arguments) => commands::list::run(arguments, root),
        Command::Search(arguments) => commands::search::run(arguments, root),
        Command::Show(arguments) => commands::show::run(arguments, root),
        Command::Path(arguments) => commands::path::run(arguments, root),
        Command::Snapshot => commands::snapshot::run(root),
        Command::Editor { .. } => commands::editor::run(root),
        Command::Frontend { .. } => commands::frontend::run(root),
        Command::Work(arguments) => commands::work::run(arguments, root),
        Command::Wait(arguments) => commands::wait::run(arguments, root),
        Command::Tag(arguments) => commands::tag::run(arguments.command, root),
        Command::Priority(arguments) => commands::priority::run(arguments.command, root),
        Command::Statement(arguments) => commands::statement::run(arguments, root),
        Command::Title(arguments) => match arguments.command {
            TitleCommand::Set(arguments) => commands::title::run(arguments, root),
        },
        Command::Evidence(arguments) => commands::evidence::run(arguments, root),
        Command::Outcome(arguments) => match arguments.command {
            OutcomeCommand::Set(arguments) => commands::outcome::run(arguments, root),
        },
        Command::Close(arguments) => commands::close::run(arguments, root),
        Command::Check(arguments) => commands::check::run(arguments, root),
    }
}
