//! Core ledger model and the filesystem adapter used by the command-line app.

pub mod cache;
pub mod check;
pub mod cli;
pub mod diagnostic;
pub mod filesystem;
pub mod frontend;
/// Experimental dependency layout candidate; not a supported frontend protocol.
pub mod graph_layout;
pub mod installation;
pub mod issue;
pub mod ledger;
pub mod mutation;
pub mod query;
pub mod record;
pub mod reference;
pub mod snapshot;
pub mod wait_graph;
pub mod wire;
pub mod work_log;
pub mod work_wire;

pub mod editor;
