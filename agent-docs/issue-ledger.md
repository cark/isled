# Optional local issue ledger

Isled can dogfood its own local ledger, but contributing does not require an
existing installation or access to a maintainer's private issues. Build the CLI
using [contributor instructions](../CONTRIBUTING.md) before trying it in a temporary
project. Keep tests and demonstrations separate from real project ledgers.

A personal `.issues/` ledger is ignored and is not distributed with this checkout.
Use the [consumer skill](../skills/isled/SKILL.md) and current CLI help for its
semantic commands, links, mutation scope and recovery. Set explicit authority
for durable bookkeeping and closure in the consuming project; a finding, passing
test or implementation does not itself grant that authority.

Public design and contributor requirements belong in maintained documentation,
so a private issue file is never the only explanation of an accepted decision.
Do not add private issue paths to public documentation or copy personal issue
history into fixtures. Keep synthetic fixtures reproducible and clearly scoped.
