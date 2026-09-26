//! Pure mutation entry points and opaque publication plans.
mod add;
mod close;
mod completion;
mod copied_titles;
pub mod editor;
mod error;
mod evidence;
mod outcome;
mod plan;
mod repair;
mod selection;
mod statement;
mod tags;
mod title;
mod wait;
pub use add::{add_record_validated, derive_slug};
pub use close::{CloseOutcome, close_issue};
pub use completion::{ParseSectionTextError, SectionText};
pub use copied_titles::repair_copied_titles;
pub use error::MutationError;
pub use evidence::evidence_add;
pub use outcome::outcome_set;
pub use plan::{MutationPlan, Replacement, changes_closed_issue};
use plan::{plan_document_replacements, plan_record_replacement};
pub use repair::relation_repair;
use selection::{parse_record_document, parse_record_view, unique_record};
pub use statement::{
    AddStatementText, DEFAULT_SEPARATOR, MatchSelection, ParseAddStatementTextError,
    ParseStatementTextError, StatementAction, StatementEditError, StatementReplacement,
    StatementText, StdinStatementText, statement_mutate, statement_mutate_stdin, statement_replace,
};
pub use tags::{PriorityOutcome, priority_clear, priority_set, tag_add, tag_remove};
pub use title::{ParseTitleTextError, TitleText, title_set};
pub use wait::{wait_add_indexed, wait_remove};

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn input_types_reject_ambiguous_multiline_values() {
        assert!(TitleText::parse("Valid title").is_ok());
        assert!(TitleText::parse("two\nlines").is_err());
        assert!(StatementText::try_parse("one line").is_ok());
        assert!(SectionText::try_parse("one line").is_ok());
    }
}
