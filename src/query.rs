//! Pure query entry points; implementations are grouped by responsibility.

pub mod dependency;
mod error;
mod filters;
mod list;
mod lookup;
mod records;
mod search;
mod wait;

pub use error::QueryError;
pub use filters::Filters;
pub use list::{list, list_headers, list_headers_with_paths, list_with_paths};
pub use lookup::{OutputPaths, path, path_identities, show};
pub use search::{
    ParseSearchSnippetsError, SearchSnippets, search_parsed, search_parsed_with_paths,
};
pub use wait::{wait_show, wait_show_headers, wait_show_headers_with_paths, wait_show_with_paths};
