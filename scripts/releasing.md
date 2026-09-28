# Preparing a release

This prepares artifacts for the [accepted distribution contract](../agent-docs/decisions.md#public-installation-direction-planned).
The [package-manager recipes](../frontends/emacs/packaging.md), managed installer
and their isolated checks are prepared alongside these artifacts. Users follow the [installation guide](../README.md#installation) for public
packages, standalone binaries and source alternatives.
The [installer check](../frontends/emacs/packaging.md#shared-installer-boundary)
uses these staged binaries to exercise package-managed setup before publication.

## Build identity

Cargo, Cargo.lock, the Nix package and `isled.el` carry one release version.
`isled-required-cli-version` is a separate explicit pin: package managers may
assign their own frontend version. Staging rejects mismatched declarations.

Ordinary `cargo build` reports `isled VERSION-dev`. Versioned packaging uses
`cargo build --release --features release-binary --locked` and reports
`isled VERSION`. The Nix package selects that feature too. `--version` and `-V`
never discover or change a ledger. A version string identifies the build; it
is not proof that GitHub published it.

Snapshot or commit the candidate before staging. Every native part records the
same full source commit. Staging checks the on-disk tracked tree against that
commit and rejects untracked source. No tag is needed yet.

## Native staging

The [Release staging workflow](../.github/workflows/release.yml) runs manually or
when the preparation branch `release-artifacts` is pushed. It does not run on a
schedule, create a release, push a tag or advance a distribution branch.
That branch also starts the full three-platform [CI workflow](../.github/workflows/ci.yml).
On that preparation branch, CI omits the public-download check: the new pin is
not public yet, and the staging workflow tests its actual candidate assets.
Run the public-download check after publication before promoting distribution refs.
Ordinary branch and tag pushes start neither workflow. Pull requests receive
one Linux CI job; manual CI runs provide all three platforms whenever needed.

The three jobs build on the same native runners as source CI, using Rust 1.97.1
and the [pinned full editors](../CONTRIBUTING.md#github-ci). Each job:

1. Checks version consistency and runs the Rust suite in release mode.
2. Builds the versioned executable and inspects native linkage and requirements.
3. Writes an archive, verifies its SHA-256, extracts the complete fixed bundle,
   and verifies every file before executing the CLI.
4. Tests standalone installation, stable paths and CLI operations in temporary storage, then runs
   the complete Emacs static/ERT entry point against the extracted executable.
5. Writes a build receipt only after those checks pass.

The assembly job accepts all three receipts from that exact revision, builds the
Emacs package, writes the manifest/checksums, and checks package installation in
a fresh Emacs process. The downloadable Actions artifact is `release-candidate`;
intermediate native parts are also retained for 14 days.

Each builder also creates a disposable version-only upgrade source using
`release_upgrade.py`. It increments the patch version in Cargo, the lockfile,
Nix and the frontend pin, then commits those changes with a deterministic
identity. The main checkout stays unchanged. The second set is named
`upgrade-candidate`; it is test material and must never be published as a release.

After assembly, three fresh native jobs install the actual packages and CLIs.
They test automatic setup, cancellation, missing/interrupted/corrupt downloads, retries,
offline cache reuse after package replacement, explicit executables, a real pin
upgrade while the old executable is running, and frontend rollback. Each editor
starts with an empty tool PATH and private state. On macOS, the check requires
Gatekeeper assessment to remain enabled; it changes no security or quarantine
settings. The `install-OS` artifacts retain case logs and an identity receipt.
The workflow passes only when all three installation jobs pass.

The same jobs test standalone installation and rollback with an empty PATH,
and verify that changing `current` cannot redirect an already prepared frontend.
Windows additionally creates an ephemeral standard account and checks junction
creation, upgrade, rollback and interrupted-switch recovery with no administrator
rights, symbolic-link privilege or Developer Mode. This is a hosted native check,
not evidence of Windows 10 or desktop SmartScreen behavior.
The harness temporarily disables Developer Mode on the disposable Windows runner
when its image enables it, and restores that setting afterwards. The standard-user
child asserts the restricted conditions before running the installer.

The owned loopback server substitutes only the request destination. These native
checks exercise normal selection, verification, extraction and execution. Public
GitHub delivery and published asset availability still need the live checks below.

For a local native build, use the [contributor tool and dependency setup](../CONTRIBUTING.md).
Linux needs `musl-gcc` and `readelf`; macOS needs its Xcode command-line tools;
Windows needs MSVC including `dumpbin` and PowerShell. These are maintainer tools,
not extra programs users need for checksum verification.

From the checkout root, with an isolated `ISLED_CHECK_PACKAGE_DIR`:

```console
python3 -B scripts/stage-release.py build \
  --target x86_64-unknown-linux-musl --revision COMMIT \
  --output target/release-parts/linux
```

Use the corresponding Rust target on each other native system. A cross-build
is rejected. Output directories must be new, so old and new candidates cannot
silently mix. With jj, obtain `COMMIT` from `jj log -r @ --no-graph -T commit_id`;
ordinary Git defaults to `HEAD`.

Collect the three part directories, then assemble them from the same checkout:

```console
python3 -B scripts/stage-release.py assemble --revision COMMIT \
  --parts target/release-parts --output target/release-candidate
python3 -B scripts/stage-release.py verify target/release-candidate
ISLED_PACKAGE_ARCHIVE="$PWD/target/release-candidate/isled-0.33.1.tar" \
  emacs -Q --batch -l frontends/emacs/test/package-install.el
```

The last command also needs `ISLED_CHECK_PACKAGE_DIR`. It uses already installed
dependencies and a temporary package directory; it cannot download dependencies
or change a normal Emacs installation. `verify` executes no binaries and can
inspect the complete set on any platform.

## Artifact contract

For version `0.33.1`, the set contains:

| File | Contents |
| --- | --- |
| `isled-0.33.1-x86_64-unknown-linux-musl.tar.gz` | Linux executable, license and complete skill bundle |
| `isled-0.33.1-aarch64-apple-darwin.tar.gz` | macOS executable, license and complete skill bundle |
| `isled-0.33.1-x86_64-pc-windows-msvc.zip` | Windows executable, license and complete skill bundle |
| `isled-0.33.1.tar` | Installable Emacs source package |
| `isled-0.33.1-TARGET.build.json` (one per target) | Source identity, build settings, platform inspection and completed checks |
| `isled-0.33.1-manifest.json` | Release identity and exact artifact descriptors |
| `isled-0.33.1-SHA256SUMS` | SHA-256 of all the preceding files, including the manifest |

Each CLI archive contains six regular files under `isled-VERSION-TARGET/`:
`isled` (`isled.exe` on Windows), `LICENSE`, `bundle.json`, `skill/SKILL.md`,
`skill/references/mutations.md` and `skill/references/recovery.md`.
Archives have normalized timestamps and modes; identical inputs produce identical
archives. This does not promise reproducible Rust builds across toolchains.

`bundle.json` schema 1 records `version`, `target` and a `files` array containing
exactly the other five files. Each entry has its relative `name`, byte `size` and
lowercase hexadecimal `sha256`. All members are verified before installation.
The manifest itself is verified against its descriptor in release manifest schema 2.

This format starts with 0.33.0 and implements the
[shared installation design](../agent-docs/decisions.md#shared-cli-and-skill-installation).
Published 0.32.0 archives remain immutable; older frontends retain their original
installer and storage. Prepare and publish the new CLI assets before promoting
an Emacs pin that requires this bundle format.

The Emacs tar contains an `isled-VERSION/` directory. Its generated `isled-pkg.el`
comes from the headers in `isled.el`; source, guides, demo GIFs and the root license
are included. Tests, bytecode and contributor-local state are excluded.

Release manifest schema 2 has `version`, `tag`, full source `revision`, `repository`,
`emacs`, and `binaries` keyed by exact Rust target. Each binary entry contains:

- `archive`: basename `name`, byte `size` and lowercase hexadecimal `sha256`.
- `executable`: exact archive `member`, byte `size` and `sha256`.
- `bundle`: exact `bundle.json` archive `member`, byte `size` and `sha256`.
- `minimum_os`: intended compatibility floor, not a native-test claim.
- `build_report`: the corresponding receipt's name, size and SHA-256.

`emacs` uses the same asset descriptor as `archive`. The tag is `vVERSION`.
The installer can therefore use the declared CLI pin to select this exact URL:

```text
https://github.com/cark/isled/releases/download/vVERSION/isled-VERSION-manifest.json
```

Asset URLs use the same release-specific prefix and their declared basenames.
There is no `latest` lookup. Download over HTTPS, validate identity and target,
then verify the archive and complete bundle before executing the CLI,
including `--version`. Reject missing, malformed or mismatched hashes. The
Emacs installer uses built-in hashing, with no external checksum/signature tool.
Checksums from the same GitHub release establish integrity within that trust
boundary; they are not an independent publisher signature.

## Platform evidence and limits

Linux uses generic x86-64 Rust/C flags, musl and bundled SQLite. Staging rejects
ELF dynamic-loader or shared-library dependencies. Native tests run on the hosted
kernel; Linux 5.4 remains an untested compatibility target.

Windows uses generic x86-64 and a statically linked MSVC CRT. Staging records PE
headers and imported functions, rejects external VC/SQLite runtime dependencies,
and checks that header OS/subsystem versions do not exceed Windows 10. Those
checks are not a complete API compatibility proof. Windows 10 and desktop
SmartScreen behavior remain untested on the Windows Server runner. The receipt
records Authenticode status; publisher signing is outside the release policy.

macOS sets Rust and C deployment targets to 15.0, rejects non-system dependencies,
and records `otool`, `codesign` and `spctl` results. ARM64 linker signing is ad hoc;
it requires no signing identity and is not Developer ID signing or notarization.
The [release contract](../agent-docs/decisions.md#public-installation-direction-planned)
excludes publisher signing and notarization. A `spctl` rejection alone does not
establish an installation failure. Final acceptance must exercise the normal
Emacs download, verification and execution route without changing macOS security
settings. If that route requires signing or notarization, drop macOS support.
Native CLI/Emacs tests do not establish browser-quarantined installation behavior;
record that separately when documenting standalone downloads.

These checks establish candidate evidence, not a claim of a published, signed,
or fully accepted end-user installation. Record native results and unresolved
distribution behavior before proceeding to publication.

## Live publication checks

After publication, `python3 -B scripts/check-published-cli.py --dependencies
/path/to/check-packages --output /path/to/new-check` anonymously retrieves the
complete release selected by the current frontend pin. It verifies all assets,
runs the installed package through real GitHub first use and offline reuse,
then runs the source frontend suite against that managed CLI. CI runs the same
check on Linux for pull requests and on all three platforms for release
preparation or manual runs. After publishing a new CLI pin, run CI manually at
the accepted revision to check its public delivery on all three platforms.
A missing release fails; there
is no source-build fallback. Keep the receipts and compare their source/package
identity with the accepted candidate.

Advance the `release` branch only after live first use passes. Check the public
manager recipes with `check-package-recipes.py --published` using the documented
[check arguments](../frontends/emacs/packaging.md#reproduce-the-packaging-checks).

## Draft preparation and final publication

Download a successful workflow's complete candidate:

```console
gh run download RUN_ID --repo cark/isled --name release-candidate \
  --dir target/release-candidate
python3 -B scripts/stage-release.py verify target/release-candidate
```

Write release notes in a separate file, then explicitly create a draft:

```console
python3 -B scripts/stage-release.py draft target/release-candidate \
  --notes /path/to/release-notes.md
```

This verifies the complete set and remote source identity before uploading it
as an unpublished draft, then verifies its uploaded names, sizes and hashes through
the release ID. Drafts need not have a Git tag yet. An existing draft makes the
command stop unless `--replace-draft` is explicitly supplied. That option replaces
the expected assets and notes while preserving draft status; it refuses published
releases, existing Git tags and unexpected draft assets. Upload failure can
leave a partial draft; inspect it and rerun with `--replace-draft` to repair it.
The helper never
publishes a release, creates a tag itself, changes repository settings or pushes
branches. Draft assets require maintainer authentication; ordinary users cannot
download them yet.

Rebuild after recipes or the installer change. The final complete candidate must
come from one source revision with fresh native receipts, package and checksums.
Then perform clean-install, upgrade and rollback checks through the normal setup
path against staged downloads. Freeze the final tag identity only after that
acceptance. Enable immutable releases and publish as a separate maintainer action;
verify public downloads and the live installer before advancing `release` for
direct Git installation. MELPA submission follows when its requirements are met;
archive listing does not delay the first release. Corrections after immutable
publication need a new version.
