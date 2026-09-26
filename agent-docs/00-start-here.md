# Project guide

[Contributing](../CONTRIBUTING.md) owns environment setup and validation commands.
Read only the routes relevant to the change:

- Engineering requirements: [coding standards](coding-standards.md).
- Scope, validation, documentation and public/private boundary: [workflow](workflow.md).
- Preservation guarantees and change policy: [compatibility](parity-contract.md).
- Rust responsibilities: [module map](code-organization.md) and [refactoring](refactoring.md).
- Cache architecture and performance: [cache design](cache-design.md).
- Accepted rationale: [decisions](decisions.md) and [dependency view](dependency-graph-view.md).
- User-facing CLI, storage and wire contracts: [user guide](../user-docs/README.md).
- Emacs setup and use: [frontend README](../frontends/emacs/README.md) and [user guide](../frontends/emacs/user-guide.md).
- Emacs implementation, code map and isolated validation: [frontend contributor guide](../frontends/emacs/CONTRIBUTING.md).
- Optional contributor tools: [script guide](../scripts/README.md) and [Rust navigation](rust-navigation.md).
- Optional local release installation: [dogfooding](dogfooding.md).
- Optional issue-ledger workflow: [ledger guidance](issue-ledger.md).

The [knowledge ownership map](coding-standards.md#knowledge-ownership) names each
canonical home. Product documentation and accepted rationale must stand on their
own without private issue records, personal configuration or session history.
