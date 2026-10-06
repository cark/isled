//! Stable command help and missing-command inventory.
use super::Cli;
use clap::CommandFactory;
use std::ffi::OsString;

pub fn missing_command_topic(arguments: impl IntoIterator<Item = OsString>) -> Option<Vec<String>> {
    let arguments = arguments.into_iter().collect::<Vec<_>>();
    let mut index = 0;
    while index < arguments.len() {
        let value = arguments[index].to_string_lossy();
        if value == "--root" {
            if index + 1 >= arguments.len() {
                return None;
            }
            index += 2;
        } else if value.starts_with("--root=") {
            index += 1;
        } else {
            break;
        }
    }
    match &arguments[index..] {
        [] => Some(Vec::new()),
        [command]
            if matches!(
                command.to_str(),
                Some(
                    "work"
                        | "tag"
                        | "cache"
                        | "priority"
                        | "wait"
                        | "statement"
                        | "title"
                        | "evidence"
                        | "outcome"
                )
            ) =>
        {
            Some(vec![command.to_string_lossy().into_owned()])
        }
        _ => None,
    }
}

pub fn render_help(topic: &[String]) -> Result<Vec<u8>, clap::Error> {
    let mut selected = build_command();
    for name in topic {
        selected = selected
            .find_subcommand(name)
            .cloned()
            .ok_or_else(|| clap::Error::new(clap::error::ErrorKind::InvalidSubcommand))?;
    }
    let binary_name = if topic.is_empty() {
        "isled".to_owned()
    } else {
        format!("isled {}", topic.join(" "))
    };
    selected = selected.bin_name(binary_name);
    let mut output = Vec::new();
    selected.write_long_help(&mut output)?;
    output.push(b'\n');
    Ok(output)
}

pub(super) fn build_command() -> clap::Command {
    Cli::command()
        .long_about(TOP_HELP)
        .after_help(TOP_AFTER)
        .mut_subcommand("install", |value| value.after_help("Run the executable from a complete extracted release archive. Verify and copy the executable, license and complete skill into versions/VERSION, then select that bundle through current. Existing versions are retained for rollback. Rerun an older bundle's installer to select it again. No download, PATH change, agent configuration edit or ledger access occurs. Cargo and Nix installations remain separately managed. --directory overrides the platform user-data directory. Both install and installation print full paths through current; --json emits installation schema 1."))
        .mut_subcommand("installation", |value| value.after_help("Inspect the selected managed bundle without creating storage or accessing a ledger. Prints the stable current executable, skill directory, SKILL.md and PATH directory. --json emits schema 1: root, version, program (exact versioned executable), executable, skill, skill_file and path_directory. version/program are null when no bundle is selected. --directory uses a custom installation root."))
        .mut_subcommand("work", |value| value.after_help(WORK_HELP))
        .mut_subcommand("init", |value| value.after_help(INIT_HELP))
        .mut_subcommand("add", |value| value.after_help(ADD_HELP))
        .mut_subcommand("cache", |value| {
            value.mut_subcommand("refresh", |leaf| leaf.after_help(CACHE_REFRESH_HELP))
        })
        .mut_subcommand("list", |value| {
            value.after_help(format!("{LIST_HELP}\n\n{CACHE_READ_HELP}"))
        })
        .mut_subcommand("search", |value| value.after_help(SEARCH_HELP))
        .mut_subcommand("show", |value| {
            value.after_help(format!("{SHOW_HELP}\n\n{CACHE_READ_HELP}"))
        })
        .mut_subcommand("path", |value| {
            value.after_help(format!("{PATH_HELP}\n\n{CACHE_READ_HELP}"))
        })
        .mut_subcommand("snapshot", |value| value.after_help(SNAPSHOT_HELP))
        .mut_subcommand("frontend", |value| value.after_help(FRONTEND_HELP))
        .mut_subcommand("editor", |value| value.after_help("Editor schema 3: mode load, validate or save; id and expected select an existing record, draft supplies complete fields; close requests explicit closure of an existing issue. Inspect response ok/code even on exit 0. Validation never publishes or allocates. Publication failures may be partial; do not blindly retry creation. See user-docs/editor.md for the wire contract."))
        .mut_subcommand("tag", |value| {
            value
                .after_help(TAG_HELP)
                .mut_subcommand("add", |leaf| leaf.after_help(TAG_ADD_HELP))
                .mut_subcommand("remove", |leaf| leaf.after_help(TAG_REMOVE_HELP))
        })
        .mut_subcommand("priority", |value| {
            value
                .after_help(PRIORITY_HELP)
                .mut_subcommand("set", |leaf| leaf.after_help(PRIORITY_SET_HELP))
                .mut_subcommand("clear", |leaf| leaf.after_help(PRIORITY_CLEAR_HELP))
        })
        .mut_subcommand("wait", |value| {
            value
                .after_help(WAIT_HELP)
                .mut_subcommand("add", |leaf| leaf.after_help(WAIT_ADD_HELP))
                .mut_subcommand("remove", |leaf| leaf.after_help(WAIT_REMOVE_HELP))
                .mut_subcommand("repair", |leaf| leaf.after_help(WAIT_REPAIR_HELP))
                .mut_subcommand("show", |leaf| {
                    leaf.after_help(format!("{WAIT_SHOW_HELP}\n\n{CACHE_READ_HELP}"))
                })
                .mut_subcommand("tree", |leaf| {
                    leaf.after_help(format!("{WAIT_TREE_HELP}\n\n{CACHE_READ_HELP}"))
                })
        })
        .mut_subcommand("statement", |value| {
            value
                .after_help(STATEMENT_HELP)
                .mut_subcommand("set", |leaf| {
                    leaf.after_help(format!("{STATEMENT_SET_HELP}\n\n{CLOSED_EDIT_HELP}"))
                })
                .mut_subcommand("append", |leaf| {
                    leaf.after_help(format!("{STATEMENT_APPEND_HELP}\n\n{CLOSED_EDIT_HELP}"))
                })
                .mut_subcommand("replace", |leaf| {
                    leaf.after_help(format!("{STATEMENT_REPLACE_HELP}\n\n{CLOSED_EDIT_HELP}"))
                })
        })
        .mut_subcommand("title", |value| {
            value.after_help(TITLE_HELP).mut_subcommand("set", |leaf| {
                leaf.after_help(format!("{TITLE_SET_HELP}\n\n{CLOSED_EDIT_HELP}"))
            })
        })
        .mut_subcommand("evidence", |value| {
            value
                .after_help(EVIDENCE_HELP)
                .mut_subcommand("add", |leaf| {
                    leaf.after_help(format!("{EVIDENCE_ADD_HELP}\n\n{CLOSED_EDIT_HELP}"))
                })
        })
        .mut_subcommand("outcome", |value| {
            value
                .after_help(OUTCOME_HELP)
                .mut_subcommand("set", |leaf| {
                    leaf.after_help(format!("{OUTCOME_SET_HELP}\n\n{CLOSED_EDIT_HELP}"))
                })
        })
        .mut_subcommand("close", |value| value.after_help(CLOSE_HELP))
        .mut_subcommand("check", |value| value.after_help(CHECK_HELP))
}

const TOP_HELP: &str = "Maintain a project-local Markdown ledger of durable owner and steward concerns.\nUse --version to report the executable version without discovering a ledger.";
const CACHE_REFRESH_HELP: &str = "Reads Markdown regardless of timestamp hints. With ISSUE, refreshes that record and checks direct dependency neighbors. Without ISSUE, refreshes the entire ledger including additions and deletions. Inspected copied relation titles may be corrected, preserving all other bytes. Missing, incompatible, or corrupt caches rebuild automatically. Unreadable records produce incomplete-result warnings on stderr.";
const CACHE_READ_HELP: &str = "Maintains disposable metadata in .issues/.cache/. External changes have best-effort freshness; use `cache refresh ID` after a targeted external edit or `cache refresh` for ALL issues. Show and wait inspection reconcile the target and direct neighbors. Inspected copied relation titles are automatically corrected from target semantic titles, preserving all other bytes. Generated RELATION_* warnings on stderr report missing mirrors, failed title corrections, or missing/unreadable neighbors. Either surviving relation half conservatively blocks readiness. Use `wait repair` for explicit completion/removal; these are local checks, not a full graph audit. Incomplete-result warnings mean omitted metadata is not confirmed absent. Cached commands require a writable cache directory. An `edit saved; cache update failed` warning from a mutation means do not repeat that edit.";
const TOP_AFTER: &str = "To create an issue, use `isled add`; see `isled help add` for options and examples.\n\nUse `isled list` for metadata-only queries and composable status, readiness, work-state, kind, tag, or wait filters; for example, `isled list --ready --with-path`. `snapshot` is a frontend wire interface, not a routine query command.\n\nWithout --root, commands other than init discover the nearest .issues directory in the current directory or its ancestors. init uses the selected directory itself. Explicit help never discovers or mutates a project.";
const INIT_HELP: &str = "Creates PATH/.issues when absent, protects and reconciles the private next-ID counter, and adds the exact /.issues/ entry to .gitignore once. Repeating init is safe. Prints `Initialized PATH/.issues`; failures leave a diagnostic on stderr.";
const ADD_HELP: &str = "Adds one open Markdown record with a stable non-reused four-digit ID, pending evidence, and pending outcome. Supply a single-line STATEMENT argument or --stdin, never both. Stdin accepts multiline UTF-8 text through EOF; one final LF is removed as framing. Statement must be non-empty, have no leading/trailing newline, and contain no level-two (## ) headings; use ### or deeper for subsections. Input is read and validated before locking or allocating, so invalid input creates no record and consumes no ID. An omitted slug is derived from the title. At most one distinct priority tag is accepted. Prints the allocated ID, with its canonical path when --with-path is used; argument, path, and store failures occur before allocation.\n\nSingle-line Statement:\nisled add 'Improve startup' 'Explain the concern.' --kind feature\n\nMultiline Statement (quoted heredoc keeps shell characters literal):\nisled add 'New issue' --kind feature --stdin <<'EOF'\nExplain the concern.\n\n### Details\n\n- First detail.\nEOF";
const LIST_HELP: &str = "Use list for metadata-only issue selection; filters compose by intersection. Open is the default status; --all or --status replaces it. --waiting conflicts with --without-waits, and --ready selects open issues with no open blockers. Preserved relations to closed issues do not block. Output is deterministic tab-separated ID, status, kind, and title, plus canonical path with --with-path. No matches succeed silently.";
const SEARCH_HELP: &str = "Search requires at least one literal snippet and is Unicode case-insensitive across complete records; use list for filter-only metadata queries. Every snippet must occur in the same issue. Results contain a list-style header, with canonical path under --with-path, and deduplicated issue-local matching lines in snippet order; long excerpts are centered and bounded to 200 characters. No matches succeed silently.";
const SHOW_HELP: &str = "With one ID, prints complete valid-UTF-8 bytes exactly as stored after copied-title reconciliation, including malformed headings, metadata, or sections. With multiple IDs, prints valid records in requested order, including repeats. Adds a newline only between records when needed, without decorative separators. Malformed, missing, or unreadable records are omitted with ID-labelled errors on stderr; other requested records continue and any failure gives exit status 1. Relation warnings do not exclude valid records. Invalid ID arguments and unavailable stores fail the command. Shared setup, cached reads and parsing are reused. Warnings and errors go to stderr; prior stdout is flushed before issue diagnostics. Use `show ID... | less` to page records only, or `show ID... 2>&1 | less` to page both streams.";
const PATH_HELP: &str = "Resolves every requested ID before printing one ID<TAB>ABSOLUTE_PATH row in request order. Repeated IDs are preserved. Invalid, missing, duplicate, unsafe, or TSV-incompatible paths fail the entire batch without partial output.";
const SNAPSHOT_HELP: &str = "Emits one deterministic JSON object for local frontends; use list for filter-only metadata queries. The document contains schema_version 4, the canonical ledger root, ascending-ID issues and unavailable arrays. Each issue carries ID, status, kind, readiness (open with all blockers closed), title, canonical path, complete stored content, structured work state and spans, typed issue-reference annotations, and a warnings array. Each warning contains code, message, related_ids, source_id (dependent), target_id (blocker), and needs_reason for explicit completion. Missing mirrors warn on both endpoints; either surviving half blocks readiness. Inspected copied titles are automatically corrected before content and reference offsets are produced. Other relation changes require `wait repair`; local checks do not certify full graph integrity. Unreadable records appear separately with id, encoded path, and actual error, never invented issue metadata. Reference offsets remain relative to the complete UTF-8 record. Issue filenames must be valid UTF-8; root and path byte fields use base64 when needed. Unsafe paths and duplicate identities still fail without partial JSON.";

const WAIT_REPAIR_HELP: &str = "Explicitly choose the meaning of an inconsistent relation: ISSUE is the dependent, BLOCKER its prerequisite. `complete` requires both parseable endpoints and at least one surviving half; it uses current semantic titles and the existing reason. If only Blocking survives, supply --reason TEXT. `remove` removes whichever halves remain in parseable endpoints, including a reference to a missing issue; repeating removal is a no-op. It never deletes issue files or guesses whether a one-sided edit meant addition or removal. Refresh after external edits and use check for a full integrity audit.";
const TAG_HELP: &str = "Use add or remove for an idempotent desired-state mutation. Ordinary tags remain editable on closed issues. A priority tag replaces the existing priority and may only be added to an open issue.";
const TAG_ADD_HELP: &str = "Adds every tag atomically without duplicating existing ordinary tags. A batch may contain at most one distinct priority. Prints `added tags to issue ISSUE`; lookup, validation, lock, and closed-priority failures leave the record unchanged.";
const TAG_REMOVE_HELP: &str = "Removes every listed tag atomically; absent tags are ignored and priorities may be removed from closed issues. Prints `removed tags from issue ISSUE`.";
const PRIORITY_HELP: &str = "Priority is single-valued: high, normal, or low. set requires an open issue; clear is idempotent and can repair a closed issue.";
const PRIORITY_SET_HELP: &str = "Replaces any existing priority with LEVEL. Repeating the same setting succeeds unchanged. Prints `set priority for issue ISSUE to LEVEL`, or reports that it is already set.";
const PRIORITY_CLEAR_HELP: &str = "Removes any priority tag and succeeds unchanged when already untriaged. Prints `cleared priority for issue ISSUE`.";
const WAIT_HELP: &str = "Waits are directed, reason-bearing relations mirrored in both endpoint records. add checks fresh endpoints and cached graph reachability, rejecting duplicates, self-waits, closed endpoints, and detected cycles before mutation. Closure preserves relations; only open targets block. show and tree maintain the cache and may correct inspected copied relation titles, preserving all other bytes.";
const WAIT_ADD_HELP: &str = "Adds an outgoing `Waiting on` entry with its reason and the reciprocal `Blocking` entry while holding the store lock; each file replacement is atomic, not the whole pair. Both entries copy the other issue's semantic title. Prints `issue ISSUE now waits on BLOCKER`; invalid arguments, endpoints, or detected cycles leave files unchanged. Reachability uses cached relationships after refreshing endpoints and direct neighbors. After bulk external edits run `cache refresh` first; use `check` for full graph integrity.";
const WAIT_REMOVE_HELP: &str = "Removes both entries for the exact ISSUE-to-BLOCKER relation while preserving every other relation. Prints `removed wait on BLOCKER from issue ISSUE`; an absent relation fails without writing.";
const WAIT_SHOW_HELP: &str = "Always prints `Waits on` and `Waited on by` sections with stable-ID-sorted issue rows and indented reasons; empty sections contain `(none)`. Preserved historical relations may have closed endpoints. --with-path appends canonical paths to relation rows.";
const WAIT_TREE_HELP: &str = "Prints the transitive `Waiting on` tree rooted at ID; --dependents follows the reverse direction. Direct preserved relations are shown, but a relation that no longer blocks is a terminal historical leaf. Shared nodes are shown at every occurrence and expanded once. Human output contains canonical IDs, status/readiness, semantic titles, and separate reason lines; --with-path adds separate path lines. --json emits deterministic schema-versioned adjacency data, retaining the true dependent-to-dependency meaning of waits_on relations and losslessly encoded paths.";
const STATEMENT_HELP: &str = "set replaces the complete main prose; append adds a paragraph. Both accept single-line TEXT or multiline text with --stdin; replace --stdin edits a literal passage. Delete text with an empty replacement; see help statement replace for an example. All preserve metadata, work history, evidence, and outcome and may clarify closed history, while new scope belongs in a new issue.";
const STATEMENT_SET_HELP: &str = "Replaces the entire Statement with single-line TEXT or multiline UTF-8 text read to EOF with --stdin, never both. Supply only the new Statement, without a separator. One final LF is removed as input framing; other bytes are preserved. Text must be non-empty, without leading/trailing newline or level-two headings; use ### or deeper for subsections. Stdin is read and validated before locking. Identical text is a no-op. Prints `set statement for issue ISSUE`; invalid input, section structure, or a write failure leaves the record unchanged.\n\nExample (quoted heredoc keeps shell characters literal):\n  isled statement set 69 --stdin <<'EOF'\n  The complete new Statement.\n\n  ### Details\n\n  - A list item.\n  EOF";
const STATEMENT_APPEND_HELP: &str = "Adds one non-empty single-line TEXT paragraph to Statement, or multiline UTF-8 text read to EOF with --stdin. One final LF is removed as input framing; other bytes are preserved. Text must have no leading/trailing newline or level-two headings. Input is read before locking. Prints `appended statement to issue ISSUE`; invalid input, section structure, or a write failure leaves the record unchanged.\n\nExample (quoted heredoc keeps shell characters literal):\n  isled statement append 54 --stdin <<'EOF'\n  A new paragraph.\n\n  - A list item.\n  EOF";
const STATEMENT_REPLACE_HELP: &str = "Reads UTF-8 old text, exactly one whole separator line (default ---replacement---), and new text until EOF. One LF before the marker and one final LF are framing, not text. Use --separator for marker collisions. Matching is literal, case-sensitive, non-overlapping, and confined to Statement; exactly one match is required unless --occurrence N or --all is selected. No match, ambiguity, invalid framing, or invalid resulting Statement changes nothing. Statement must remain non-empty, without leading/trailing newline or level-two headings. Input is read before locking. Identical replacement is a no-op. Prints `replaced statement text in issue ISSUE`.\n\nReplace:\n  isled statement replace 54 --stdin <<'EOF'\n  Old text\n  ---replacement---\n  New text\n  EOF\n\nDelete by leaving the replacement empty (no separate delete command):\n  isled statement replace 54 --stdin <<'EOF'\n  Unwanted text\n  ---replacement---\n  EOF";
const TITLE_HELP: &str = "The semantic title lives in the Markdown heading and is independent of the stable creation-time filename slug.";
const TITLE_SET_HELP: &str = "Atomically replaces the semantic Markdown heading title on an open or closed issue and refreshes copied titles in directly related records. Stable IDs, filenames, slugs, relation meaning, and prose remain unchanged. Repeating the current title succeeds without rewriting the record. Prints `set title for issue ISSUE`.";
const EVIDENCE_HELP: &str = "Evidence supports a closure decision but remains distinct from the single current outcome. add records concrete facts without changing status or authorizing closure.";
const EVIDENCE_ADD_HELP: &str = "Appends one or more non-empty single-line entries atomically, replacing the generated Pending entry on first use. Mixing the reserved Pending. placeholder with other evidence is rejected without changes. It works for open and closed issues and prints `added evidence to issue ISSUE`.";
const OUTCOME_HELP: &str = "Outcome records an issue's single current conclusion without changing its status or authorizing closure.";
const OUTCOME_SET_HELP: &str = "Atomically replaces the pending or recorded outcome with one non-empty single-line TEXT. It works for open and closed issues and prints `set outcome for issue ISSUE`.";
const CLOSE_HELP: &str = "Atomically closes ID and stops its clock, removes current work state and priority while preserving all dependency relations as history. Relations to the closed issue stop blocking. Concrete evidence is required. A pending outcome requires --outcome TEXT; a recorded outcome rejects replacement. Repeating closure is safe. Closure is terminal; add a new issue for mistaken closure, an invalidated conclusion, or new scope.";
const CHECK_HELP: &str = "Audits every record and the high-water mark and never repairs the ledger. A clean ledger prints nothing. Findings are tab-separated LOCATOR, invariant, and detail rows on stdout and exit one; operational failures use stderr and exit two. Invariant codes include UTF-8, field, tag, wait, graph, high-water, EVIDENCE_PENDING, and OUTCOME_PENDING findings. Invalid filename bytes are escaped so recovery output remains readable.";

const CLOSED_EDIT_HELP: &str = "A successful change to the explicitly selected closed issue emits `warning: issue NNNN is closed; updating historical record` on stderr, without changing success stdout or exit status. Open issues and byte-identical no-ops do not warn. Automatic copied-title updates in related closed records do not add warnings.";

const FRONTEND_HELP: &str = r#"Read one version-4 JSON request from stdin and emit one complete JSON response.
Modes: refresh reconciles all issues; view selects cached summaries; details reads
requested issues and direct neighbors; choices selects completion candidates.
Filter status/work_state/kind/tags/text in Rust. Work summaries include state,
owner reason/question, completed seconds and a running start; details include spans. Live hashes
suppress unchanged views and details; changed details may report deletion or failure.
Optional graph layouts on view/refresh apply all filters, with prerequisites or
dependents first. Status selection is strict; hidden intermediates are never bridged.
Rows count direct prerequisites/dependents hidden by additional work-state/tag/kind/text filters. Connected groups stay together, placed by
smallest issue ID alongside independent issues. Roots occupy the first graph lane.
A separate graph hash suppresses unchanged
plans, including hidden-connection counts; requests without graph do no layout work. Graph mode needs an updated client/CLI.
Rust automatically rebuilds missing, incompatible, or corrupt caches when necessary.
See user-docs/frontend.md for the wire contract. Use list for ordinary metadata queries.

Example (open dependency graph, prerequisites first):
isled frontend --stdin <<'JSON'
{"schema_version":4,"mode":"view","filter":{"status":"open"},"graph":{"direction":"prerequisites"}}
JSON

Example (filtered open graph, showing omitted-connection counts):
isled frontend --stdin <<'JSON'
{"schema_version":4,"mode":"view","filter":{"status":"open","tags":["rust"],"text":["timeout"]},"graph":{"direction":"prerequisites"}}
JSON"#;

const WORK_HELP: &str = "Optional work tracking, separate from lifecycle and dependency readiness. queue sets Queued; start sets In progress and starts/resumes timing unless --no-clock; pause stops timing without changing state; await stops timing and selects Awaiting owner with --reason review or clarification. Clarification requires --question TEXT. unqueue stops timing and removes current work state. Repeated Start does not duplicate a running span; pause before changing activity. --at supplies actual UTC time as 'YYYY-MM-DD HH:MM:SS'. Spans survive restarts; correct ISSUE SPAN --stop TIME repairs an actual stopping time, with one-based span numbers and no overlaps. show --json emits schema 1 with state, reason, question, total_seconds and spans. list/search --work-state select a state. These actions grant no execution or closure authority; closed issues allow only historical time correction.

Examples:
  isled work queue 42
  isled work start 42 --activity Implementation
  isled work pause 42
  isled work start 42 --no-clock
  isled work await 42 --reason clarification --question 'Which platforms should this cover?'
  isled work await 42 --reason review
  isled work show 42 --json";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_command_inventory_handles_global_root_forms() {
        assert_eq!(missing_command_topic(Vec::<OsString>::new()), Some(vec![]));
        assert_eq!(
            missing_command_topic(["--root".into(), "project".into(), "wait".into()]),
            Some(vec!["wait".into()])
        );
        assert_eq!(
            missing_command_topic(["--root=project".into(), "tag".into()]),
            Some(vec!["tag".into()])
        );
        assert_eq!(
            missing_command_topic(["title".into()]),
            Some(vec!["title".into()])
        );
        assert_eq!(missing_command_topic(["--root".into()]), None);
    }
}
