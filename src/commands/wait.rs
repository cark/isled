//! Dispatch wait subcommands to their complete workflows.
mod add;
mod remove;
mod repair;
mod show;
mod tree;

use super::error::AppError;
use isled::cli::{WaitArgs, WaitCommand};
use isled::filesystem::{FilesystemError, ProjectRoot};

pub(crate) fn run(
    arguments: WaitArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    match arguments.command {
        WaitCommand::Show(arguments) => show::run(arguments, root),
        WaitCommand::Tree(arguments) => tree::run(arguments, root),
        WaitCommand::Add(arguments) => add::run(arguments, root),
        WaitCommand::Remove(arguments) => remove::run(arguments, root),
        WaitCommand::Repair {
            action,
            issue,
            blocker,
            reason,
        } => repair::run(action, issue, blocker, reason, root),
    }
}
