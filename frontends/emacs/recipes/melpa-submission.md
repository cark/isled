# MELPA submission draft

Prepare a PR titled **Add recipe for isled**, containing the
[isled recipe](melpa/isled). Do not submit until the public `release` branch,
matching CLI assets and final installation checks are ready. Confirm at least
one month of public repository history and complete the human maintainer review.
Refresh the evidence below against that final candidate before submission.

---

### Brief summary of what the package does

Isled browses and edits project-local issue ledgers inside Emacs. Issues remain
Markdown files in `.issues/`; the UI shows dependency hierarchies and readiness,
supports filtering and follows issue references. Compared with an Org TODO
workflow, it uses a dedicated issue format shared with a standalone Rust CLI.

The recipe follows `release` so package updates are paired with an available
compatible CLI. The frontend carries its exact CLI pin independently of MELPA's
package version. The first-use provisioning behavior and platform limits must
be confirmed against the final release before this submission is sent.

### Direct link to the package repository

https://github.com/cark/isled

### Your association with the package

Package maintainer.

### Relevant communications with the upstream package maintainer

None needed; submitted by the maintainer.

### Checklist

Complete these as the submitting maintainer after reviewing the final candidate:

- [ ] The package uses the GPL-compatible MIT license.
- [ ] I have read MELPA's current CONTRIBUTING.org.
- [ ] AI assistance is declared with Assisted-by headers, and I have reviewed the code.
- [ ] The package has at least one month of public repository history.
- [ ] The latest package-lint passes for the final candidate.
- [ ] The package byte-compiles cleanly and Checkdoc passes.
- [ ] I have built and installed the MELPA recipe against the published release branch.

### Validation

Replace this paragraph with the final recipe build/install result, exact source
revision, package version, CLI pin and public installation result. Local staging
checks are preparation evidence, not proof of published assets or MELPA acceptance.
