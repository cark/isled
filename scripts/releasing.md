# Preparing a release

This prepares artifacts for the [accepted distribution contract](../agent-docs/decisions.md#public-installation-direction-planned).
The managed installer and package-manager recipes are subsequent work. Current
users still follow the [source installation guide](../README.md#installation).

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
when the preparation branch `release/artifacts` is pushed. It does not run on a
schedule, create a release, push a tag or advance a distribution branch.

The three jobs build on the same native runners as source CI, using Rust 1.97.1
and Emacs 30.1. Each job:

1. Checks version consistency and runs the Rust suite in release mode.
2. Builds the versioned executable and inspects native linkage and requirements.
3. Writes an archive, verifies its SHA-256, extracts only the expected executable,
   and verifies its SHA-256 before executing it.
4. Tests version reporting and CLI operations in a temporary ledger, then runs
   the complete Emacs static/ERT entry point against the extracted executable.
5. Writes a build receipt only after those checks pass.

The final job accepts all three receipts from that exact revision, builds the
Emacs package, writes the manifest/checksums, and checks package installation in
a fresh Emacs process. The downloadable Actions artifact is `release-candidate`;
intermediate native parts are also retained for 14 days.

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
ISLED_PACKAGE_ARCHIVE="$PWD/target/release-candidate/isled-0.32.0.tar" \
  emacs -Q --batch -l frontends/emacs/test/package-install.el
```

The last command also needs `ISLED_CHECK_PACKAGE_DIR`. It uses already installed
dependencies and a temporary package directory; it cannot download dependencies
or change a normal Emacs installation. `verify` executes no binaries and can
inspect the complete set on any platform.

## Artifact contract

For version `0.32.0`, the set contains:

| File | Contents |
| --- | --- |
| `isled-0.32.0-x86_64-unknown-linux-musl.tar.gz` | Linux executable and license |
| `isled-0.32.0-aarch64-apple-darwin.tar.gz` | macOS executable and license |
| `isled-0.32.0-x86_64-pc-windows-msvc.zip` | Windows executable and license |
| `isled-0.32.0.tar` | Installable Emacs source package |
| `isled-0.32.0-TARGET.build.json` (one per target) | Source identity, build settings, platform inspection and completed checks |
| `isled-0.32.0-manifest.json` | Release identity and exact artifact descriptors |
| `isled-0.32.0-SHA256SUMS` | SHA-256 of all the preceding files, including the manifest |

CLI archives contain exactly `isled-VERSION-TARGET/isled` (`isled.exe` on Windows)
and `isled-VERSION-TARGET/LICENSE`. Archives have normalized timestamps and modes;
identical inputs produce identical archives. This does not promise bit-for-bit
reproducibility of Rust builds across toolchains or systems.

The Emacs tar contains an `isled-VERSION/` directory. Its generated `isled-pkg.el`
comes from the headers in `isled.el`; source, guides, demo GIFs and the root license
are included. Tests, bytecode and contributor-local state are excluded.

Manifest schema 1 has `version`, `tag`, full source `revision`, `repository`,
`emacs`, and `binaries` keyed by exact Rust target. Each binary entry contains:

- `archive`: basename `name`, byte `size` and lowercase hexadecimal `sha256`.
- `executable`: exact archive `member`, byte `size` and `sha256`.
- `minimum_os`: intended compatibility floor, not a native-test claim.
- `build_report`: the corresponding receipt's name, size and SHA-256.

`emacs` uses the same asset descriptor as `archive`. The tag is `vVERSION`.
The installer can therefore use the declared CLI pin to select this exact URL:

```text
https://github.com/cark/isled/releases/download/vVERSION/isled-VERSION-manifest.json
```

Asset URLs use the same release-specific prefix and their declared basenames.
There is no `latest` lookup. Download over HTTPS, validate identity and target,
then verify the archive before extraction and executable before execution,
including `--version`. Reject missing, malformed or mismatched hashes. The future
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
records Authenticode status; no publisher certificate is currently configured.

macOS sets Rust and C deployment targets to 15.0, rejects non-system dependencies,
and records `otool`, `codesign` and `spctl` results. ARM64 linker signing is ad hoc;
it is not Developer ID signing or notarization. A native CLI/Emacs pass does not
establish browser-quarantined installation behavior. Consult actual receipts
before deciding the supported download route or acquiring signing credentials.
[Apple's distribution guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
requires Developer ID signing for notarization; checksums do not replace it.

These checks establish candidate evidence, not a claim of a published, signed,
or fully accepted end-user installation. Record native results and unresolved
distribution behavior before proceeding to publication.

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
as an unpublished draft. An existing release or tag makes the command stop;
inspect an existing draft before deliberately replacing it. Upload failure can
leave a partial draft, which must be repaired before acceptance. The helper never
publishes a release, creates a tag itself, changes repository settings or pushes
branches. Draft assets require maintainer authentication; ordinary users cannot
download them yet.

Rebuild after recipes or the installer change. The final complete candidate must
come from one source revision with fresh native receipts, package and checksums.
Then perform clean-install, upgrade and rollback checks through the normal setup
path against staged downloads. Freeze the final tag identity only after that
acceptance. Enable immutable releases and publish as a separate maintainer action;
verify public downloads and the live installer before advancing `release` and
submitting the MELPA recipe. Corrections after immutable publication need a new
version.
