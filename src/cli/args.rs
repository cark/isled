//! Clap grammar and command argument data.
use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(
    name = "isled",
    about = "Maintain a project-local Markdown issue ledger",
    color = clap::ColorChoice::Never,
    term_width = 100,
    disable_version_flag = true
)]
pub struct Cli {
    /// Use PATH as the project root instead of discovering one.
    #[arg(long, value_name = "PATH")]
    pub root: Vec<PathBuf>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Initialize an ignored .issues directory.
    Init,
    /// Allocate and add a Markdown issue.
    Add(AddArgs),
    /// List issues using composable filters.
    List(FilterArgs),
    /// Search complete issue records using literal Unicode text.
    Search(SearchArgs),
    /// Inspect one raw issue or several valid records in requested order.
    Show(ShowArgs),
    /// Print canonical paths for one or more issues.
    Path(PathArgs),
    /// Emit one versioned JSON snapshot for local frontends.
    Snapshot,
    /// Serve one JSON frontend request from stdin: refresh, view, details, or choices.
    Frontend {
        /// Read the versioned JSON request from stdin.
        #[arg(long, required = true)]
        stdin: bool,
    },
    /// Load, validate or save one complete issue draft using editor JSON schema 2.
    Editor {
        /// Read the versioned request from stdin; inspect response ok/code for the result.
        #[arg(long, required = true)]
        stdin: bool,
    },
    /// Inspect or refresh the disposable SQLite cache.
    Cache(CacheArgs),
    /// Add or remove issue tags.
    Tag(TagArgs),
    /// Set or clear issue priority.
    Priority(PriorityArgs),
    /// Inspect or manage reasoned wait relations.
    Wait(WaitArgs),
    /// Set, append, or replace issue statement prose.
    Statement(StatementArgs),
    /// Set an issue's semantic title.
    Title(TitleArgs),
    /// Add concrete evidence to an issue.
    Evidence(EvidenceArgs),
    /// Set an issue's current outcome.
    Outcome(OutcomeArgs),
    /// Close an issue.
    Close(CloseArgs),
    /// Audit the whole ledger without repairing it.
    Check(CheckArgs),
}

#[derive(Debug, Args)]
pub struct CacheArgs {
    #[command(subcommand)]
    pub command: CacheCommand,
}

#[derive(Debug, Subcommand)]
pub enum CacheCommand {
    /// Reconcile one issue and direct neighbors, or the entire ledger when ISSUE is omitted.
    Refresh {
        /// Optional issue ID (1-4 digits, optional #); omission refreshes ALL issues.
        issue: Option<String>,
    },
}

#[derive(Debug, Args)]
pub struct AddArgs {
    /// Required lowercase hyphenated issue kind.
    #[arg(long, value_name = "KIND")]
    pub kind: Vec<String>,
    /// Optional lowercase hyphenated filename slug.
    #[arg(long, value_name = "SLUG")]
    pub slug: Vec<String>,
    /// Optional repeatable lowercase hyphenated tag.
    #[arg(long, value_name = "TAG")]
    pub tag: Vec<String>,
    /// Append the canonical path to the allocated ID.
    #[arg(long)]
    pub with_path: bool,
    /// Required non-empty single-line issue title without tabs.
    pub title: String,
    /// Non-empty single-line statement; omit when using --stdin.
    #[arg(required_unless_present = "stdin", conflicts_with = "stdin")]
    pub statement: Option<String>,
    /// Read a multiline UTF-8 Statement from stdin until EOF.
    #[arg(long)]
    pub stdin: bool,
}

#[derive(Clone, Debug, Args)]
pub struct FilterArgs {
    /// Include both open and closed issues.
    #[arg(long)]
    pub all: bool,
    /// Select one exact status: open or closed.
    #[arg(long, value_name = "STATUS")]
    pub status: Option<String>,
    /// Select one exact lowercase hyphenated kind; a later value wins.
    #[arg(long, value_name = "KIND")]
    pub kind: Vec<String>,
    /// Select issues carrying every comma-separated tag.
    #[arg(long, value_name = "TAG[,TAG...]")]
    pub tags: Vec<String>,
    /// Select issues with one or more waits.
    #[arg(long, action = clap::ArgAction::Count)]
    pub waiting: u8,
    /// Select issues without waits.
    #[arg(long, action = clap::ArgAction::Count)]
    pub without_waits: u8,
    /// Select open issues without waits.
    #[arg(long)]
    pub ready: bool,
    /// Select issues waiting on an ID (1-4 digits, optional #); later wins.
    #[arg(long, value_name = "ID")]
    pub waiting_on: Vec<String>,
    /// Append each issue's canonical absolute path.
    #[arg(long)]
    pub with_path: bool,
}

#[derive(Debug, Args)]
pub struct SearchArgs {
    #[command(flatten)]
    pub filters: FilterArgs,
    /// Required literal snippets; every snippet must occur in one issue.
    #[arg(value_name = "SNIPPET", trailing_var_arg = true)]
    pub snippets: Vec<String>,
}

#[derive(Debug, Args)]
pub struct IdArgs {
    /// Issue ID (1-4 digits, optional #).
    pub id: String,
}

#[derive(Debug, Args)]
pub struct ShowArgs {
    /// Issue IDs (1-4 digits, optional #), preserved in request order.
    #[arg(required = true, value_name = "ID")]
    pub ids: Vec<String>,
}

#[derive(Debug, Args)]
pub struct PathArgs {
    /// Issue IDs (1-4 digits, optional #), preserved in request order.
    #[arg(required = true)]
    pub ids: Vec<String>,
}

#[derive(Debug, Args)]
pub struct WaitArgs {
    #[command(subcommand)]
    pub command: WaitCommand,
}

#[derive(Debug, Subcommand)]
pub enum WaitCommand {
    /// Explicitly complete or remove an inconsistent relation; no inference of intent.
    Repair {
        #[arg(value_enum)]
        action: RepairAction,
        /// Dependent issue ID.
        issue: String,
        /// Blocker issue ID.
        blocker: String,
        /// Required when completing a relation whose Waiting on half is missing.
        #[arg(long)]
        reason: Option<String>,
    },
    /// Show outgoing and incoming wait relations.
    Show(WaitShowArgs),
    /// Show one transitive dependency direction as a compact tree.
    Tree(WaitTreeArgs),
    /// Add a reasoned wait relation.
    Add(WaitAddArgs),
    /// Remove a wait relation.
    Remove(WaitRemoveArgs),
}

#[derive(Clone, Copy, Debug, clap::ValueEnum)]
pub enum RepairAction {
    Complete,
    Remove,
}

#[derive(Debug, Args)]
pub struct WaitShowArgs {
    /// Append canonical paths to issue identity rows.
    #[arg(long)]
    pub with_path: bool,
    /// Issue ID whose relations are displayed (1-4 digits, optional #).
    pub id: String,
}

#[derive(Debug, Args)]
pub struct WaitTreeArgs {
    /// Follow issues that depend on ID instead of dependencies of ID.
    #[arg(long)]
    pub dependents: bool,
    /// Emit versioned adjacency-list JSON instead of a human tree.
    #[arg(long)]
    pub json: bool,
    /// Include canonical issue paths.
    #[arg(long)]
    pub with_path: bool,
    /// Root issue ID (1-4 digits, optional #).
    pub id: String,
}

#[derive(Debug, Args)]
pub struct WaitAddArgs {
    /// Open issue ID that owns the wait (1-4 digits, optional #).
    pub issue: String,
    /// Open blocker ID (1-4 digits, optional #).
    pub blocker: String,
    /// Required non-empty single-line explanation.
    pub reason: String,
}

#[derive(Debug, Args)]
pub struct WaitRemoveArgs {
    /// Issue ID that owns the wait (1-4 digits, optional #).
    pub issue: String,
    /// Blocker ID (1-4 digits, optional #).
    pub blocker: String,
}

#[derive(Debug, Args)]
pub struct TagArgs {
    #[command(subcommand)]
    pub command: TagCommand,
}

#[derive(Debug, Subcommand)]
pub enum TagCommand {
    Add(TagMutationArgs),
    Remove(TagMutationArgs),
}

#[derive(Debug, Args)]
pub struct TagMutationArgs {
    /// Issue ID to mutate (1-4 digits, optional #).
    pub issue: String,
    /// One or more lowercase hyphenated tags.
    #[arg(required = true)]
    pub tags: Vec<String>,
}

#[derive(Debug, Args)]
pub struct PriorityArgs {
    #[command(subcommand)]
    pub command: PriorityCommand,
}

#[derive(Debug, Subcommand)]
pub enum PriorityCommand {
    Set(PrioritySetArgs),
    Clear(IdArgs),
}

#[derive(Debug, Args)]
pub struct PrioritySetArgs {
    /// Open issue ID to prioritize (1-4 digits, optional #).
    pub issue: String,
    /// Priority level: high, normal, or low.
    pub level: String,
}

#[derive(Debug, Args)]
pub struct StatementArgs {
    #[command(subcommand)]
    pub command: StatementCommand,
}

#[derive(Debug, Subcommand)]
pub enum StatementCommand {
    Set(StatementInputArgs),
    Append(StatementInputArgs),
    Replace(StatementReplaceArgs),
}

#[derive(Debug, Args)]
pub struct StatementInputArgs {
    /// Issue ID to mutate (1-4 digits, optional #).
    pub issue: String,
    /// Non-empty single-line text; omit when using --stdin.
    #[arg(required_unless_present = "stdin", conflicts_with = "stdin")]
    pub text: Option<String>,
    /// Read multiline Statement text from stdin until EOF.
    #[arg(long)]
    pub stdin: bool,
}

#[derive(Debug, Args)]
pub struct StatementReplaceArgs {
    /// Issue ID to mutate (1-4 digits, optional #).
    pub issue: String,
    /// Read old text, separator line, and replacement from stdin until EOF.
    #[arg(long, required = true)]
    pub stdin: bool,
    /// Whole-line marker separating old text from replacement text.
    #[arg(long, default_value = crate::mutation::DEFAULT_SEPARATOR)]
    pub separator: String,
    /// Replace only the Nth non-overlapping match (one-based).
    #[arg(long, value_name = "N", conflicts_with = "all")]
    pub occurrence: Option<std::num::NonZeroUsize>,
    /// Replace every non-overlapping match, not just a unique one.
    #[arg(long)]
    pub all: bool,
}

#[derive(Debug, Args)]
pub struct ContentTextArgs {
    /// Issue ID to mutate (1-4 digits, optional #).
    pub issue: String,
    /// Required non-empty single-line text.
    pub text: String,
}

#[derive(Debug, Args)]
pub struct TitleArgs {
    #[command(subcommand)]
    pub command: TitleCommand,
}

#[derive(Debug, Subcommand)]
pub enum TitleCommand {
    Set(TitleSetArgs),
}

#[derive(Debug, Args)]
pub struct TitleSetArgs {
    /// Issue ID to mutate (1-4 digits, optional #).
    pub issue: String,
    /// New non-empty single-line semantic title without tabs.
    pub title: String,
}

#[derive(Debug, Args)]
pub struct EvidenceArgs {
    #[command(subcommand)]
    pub command: EvidenceCommand,
}

#[derive(Debug, Subcommand)]
pub enum EvidenceCommand {
    Add(EvidenceAddArgs),
}

#[derive(Debug, Args)]
pub struct EvidenceAddArgs {
    /// Issue ID to mutate (1-4 digits, optional #).
    pub issue: String,
    /// One or more concrete non-empty single-line entries.
    #[arg(required = true)]
    pub text: Vec<String>,
}

#[derive(Debug, Args)]
pub struct OutcomeArgs {
    #[command(subcommand)]
    pub command: OutcomeCommand,
}

#[derive(Debug, Subcommand)]
pub enum OutcomeCommand {
    Set(ContentTextArgs),
}

#[derive(Debug, Args)]
pub struct CloseArgs {
    /// Replace the generated pending outcome atomically.
    #[arg(long, value_name = "TEXT")]
    pub outcome: Vec<String>,
    /// Issue ID to close (1-4 digits, optional #).
    pub id: String,
}

#[derive(Debug, Args)]
pub struct CheckArgs {
    #[arg(allow_hyphen_values = true, trailing_var_arg = true, hide = true)]
    pub unexpected: Vec<String>,
}
