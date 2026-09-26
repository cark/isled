# Refactoring Isled

Follow the [project refactoring requirements](coding-standards.md#refactoring).
Name the responsibility, intended destination and behavior to preserve. Inspect
callers before choosing boundaries; use focused, independently reviewable changes.
A separate reviewer or complete acceptance pass is not implied by each increment.

Read the [compatibility contract](parity-contract.md) and [module map](code-organization.md).
Preserve validation, read, lock, publication, warning and cleanup ordering;
user-authored bytes and error behavior remain within the established contract.
Internal changes require caller/scope review and do not authorize unrelated naming
sweeps or features. Rust library source compatibility is not a supported public API.

Use [proportionate validation](workflow.md#validation-scope), including whole-file
cohesion, obsolete-path and operation-wide cost review. Update affected maps and
canonical docs in the same change. Optional maintainer installation, publishing
and issue closure retain their separate authorization boundaries.
