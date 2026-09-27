#![cfg(any(
    all(target_os = "linux", target_arch = "x86_64"),
    all(target_os = "macos", target_arch = "aarch64"),
    all(target_os = "windows", target_arch = "x86_64")
))]

use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
use std::process::Command;

fn run(program: &Path, args: &[&str]) -> std::process::Output {
    Command::new(program).args(args).output().unwrap()
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[test]
fn extracted_bundle_installs_without_a_ledger_and_reports_stable_paths() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("download");
    fs::create_dir_all(source.join("skill/references")).unwrap();
    let executable = if cfg!(windows) { "isled.exe" } else { "isled" };
    let program = source.join(executable);
    fs::copy(env!("CARGO_BIN_EXE_isled"), &program).unwrap();
    let mut files = Vec::new();
    for name in [
        executable,
        "LICENSE",
        "skill/SKILL.md",
        "skill/references/mutations.md",
        "skill/references/recovery.md",
    ] {
        let path = source.join(name);
        if name != executable {
            fs::write(&path, name).unwrap();
        }
        let bytes = fs::read(path).unwrap();
        files.push(serde_json::json!({"name": name, "size": bytes.len(), "sha256": hash(&bytes)}));
    }
    let target = if cfg!(windows) {
        "x86_64-pc-windows-msvc"
    } else if cfg!(target_os = "macos") {
        "aarch64-apple-darwin"
    } else {
        "x86_64-unknown-linux-musl"
    };
    let bundle = serde_json::json!({"schema_version": 1, "version": isled::cli::VERSION, "target": target, "files": files});
    fs::write(
        source.join("bundle.json"),
        serde_json::to_vec(&bundle).unwrap(),
    )
    .unwrap();
    let root = temp.path().join("chosen storage é");
    let output = run(
        &program,
        &["install", "--directory", root.to_str().unwrap(), "--json"],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["version"], isled::cli::VERSION);
    assert_eq!(
        Path::new(report["executable"].as_str().unwrap()),
        root.join("current").join(executable)
    );
    assert_eq!(
        fs::read_to_string(report["skill_file"].as_str().unwrap()).unwrap(),
        "skill/SKILL.md"
    );
    let current = root.join("current").join(executable);
    assert!(run(&current, &["--version"]).status.success());
    let inspected = run(
        &current,
        &[
            "installation",
            "--directory",
            root.to_str().unwrap(),
            "--json",
        ],
    );
    assert!(inspected.status.success());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&inspected.stdout).unwrap(),
        report
    );
    let repeated = run(
        &current,
        &["install", "--directory", root.to_str().unwrap()],
    );
    assert!(
        repeated.status.success(),
        "{}",
        String::from_utf8_lossy(&repeated.stderr)
    );
    assert!(String::from_utf8_lossy(&repeated.stdout).contains("Skill instructions:"));
    assert!(!root.join(".issues").exists());
}

#[test]
fn source_install_explains_missing_bundle_without_writing_storage() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("not-created");
    let output = run(
        Path::new(env!("CARGO_BIN_EXE_isled")),
        &["install", "--directory", root.to_str().unwrap()],
    );
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("complete release archive"));
    assert!(!root.exists());
}
