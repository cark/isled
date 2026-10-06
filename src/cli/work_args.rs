//! Small work-action grammar shared by humans and coordinating agents.
use clap::{Args, Subcommand, ValueEnum};

#[derive(Debug, Args)]
pub struct WorkArgs {
    #[command(subcommand)]
    pub command: WorkCommand,
}
#[derive(Debug, Subcommand)]
pub enum WorkCommand {
    /// Queue an issue without starting its clock.
    Queue(WorkAtArgs),
    /// Return an issue to Not queued and stop any clock.
    Unqueue(WorkAtArgs),
    /// Start or resume work, timing by default.
    Start(WorkStartArgs),
    /// Stop timing, leaving the work state unchanged.
    Pause(WorkAtArgs),
    /// Stop timing and wait for owner review or clarification.
    Await(WorkAwaitArgs),
    /// Correct a span's actual stop time (span numbers start at 1).
    Correct(WorkCorrectArgs),
    /// Show state, elapsed work and the span history.
    Show(WorkShowArgs),
}
#[derive(Debug, Args)]
pub struct WorkAtArgs {
    pub id: String,
    /// Actual transition time in UTC: YYYY-MM-DD HH:MM:SS; default is now.
    #[arg(long)]
    pub at: Option<String>,
}
#[derive(Debug, Args)]
pub struct WorkStartArgs {
    #[command(flatten)]
    pub target: WorkAtArgs,
    /// Change state without timing; stop a currently running clock.
    #[arg(long)]
    pub no_clock: bool,
    /// Optional short label for this work span.
    #[arg(long, conflicts_with = "no_clock")]
    pub activity: Option<String>,
}
#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum OwnerReason {
    Review,
    Clarification,
}
#[derive(Debug, Args)]
pub struct WorkAwaitArgs {
    #[command(flatten)]
    pub target: WorkAtArgs,
    #[arg(long, value_enum)]
    pub reason: OwnerReason,
    /// Required for clarification; omit for review.
    #[arg(long)]
    pub question: Option<String>,
}
#[derive(Debug, Args)]
pub struct WorkCorrectArgs {
    pub id: String,
    pub span: std::num::NonZeroUsize,
    /// Actual stop time in UTC: YYYY-MM-DD HH:MM:SS.
    #[arg(long)]
    pub stop: String,
}
#[derive(Debug, Args)]
pub struct WorkShowArgs {
    #[command(flatten)]
    pub target: WorkAtArgs,
    /// Emit work schema 1 JSON with structured spans and the pending question.
    #[arg(long)]
    pub json: bool,
}
