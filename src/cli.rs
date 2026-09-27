//! CLI parsing and invocation-error adaptation.
mod args;
mod help;
pub use args::*;
use clap::FromArgMatches;
use clap::builder::StyledStr;
use clap::error::{ContextKind, ContextValue, ErrorKind};
use help::build_command;
pub use help::{missing_command_topic, render_help};

/// Product version, with an explicit marker for ordinary contributor builds.
#[cfg(feature = "release-binary")]
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
#[cfg(not(feature = "release-binary"))]
pub const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "-dev");

pub fn parse() -> Result<Cli, clap::Error> {
    let mut matches = match build_command().try_get_matches_from(std::env::args_os()) {
        Ok(matches) => matches,
        Err(mut error) => {
            add_command_hint(&mut error);
            return Err(error);
        }
    };
    Cli::from_arg_matches_mut(&mut matches)
}

fn add_command_hint(error: &mut clap::Error) {
    if error.kind() != ErrorKind::InvalidSubcommand {
        return;
    }
    let Some(ContextValue::String(command)) = error.get(ContextKind::InvalidSubcommand) else {
        return;
    };
    let hint = match command.as_str() {
        "ready" => "use 'isled list --ready' to select ready issues",
        "create" => {
            "use 'isled add' to create an issue; see 'isled help add' for options and examples"
        }
        _ => return,
    };
    let mut suggestion = StyledStr::new();
    suggestion.push_str(hint);
    error.remove(ContextKind::SuggestedSubcommand);
    error.insert(
        ContextKind::Suggested,
        ContextValue::StyledStrs(vec![suggestion]),
    );
}
