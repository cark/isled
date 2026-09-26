//! Cache integration contracts; shared fixture code never touches a live ledger.

#[path = "cache/fingerprints.rs"]
mod fingerprints;
#[path = "cache/fixture.rs"]
mod fixture;
#[path = "cache/freshness.rs"]
mod freshness;
#[path = "cache/recovery.rs"]
mod recovery;
#[path = "cache/relations.rs"]
mod relations;

#[path = "cache/retained_warnings.rs"]
mod retained_warnings;

#[path = "cache/layout.rs"]
mod layout;
