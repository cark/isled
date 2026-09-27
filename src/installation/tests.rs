use super::*;
use bundle::{FileEntry, SKILL_FILES, digest, target};

fn fixture(parent: &Path, version: &str) -> (PathBuf, Bundle) {
    let root = parent.join(format!("source-{version}"));
    fs::create_dir_all(root.join("skill/references")).unwrap();
    let files = [executable(), "LICENSE"]
        .into_iter()
        .chain(SKILL_FILES)
        .map(|name| {
            let path = root.join(name);
            fs::write(&path, format!("{version}: {name}\n")).unwrap();
            FileEntry {
                name: name.into(),
                size: fs::metadata(&path).unwrap().len(),
                sha256: digest(&path).unwrap(),
            }
        })
        .collect();
    let bundle = Bundle {
        schema_version: 1,
        version: version.into(),
        target: target().unwrap().into(),
        files,
    };
    fs::write(
        root.join("bundle.json"),
        serde_json::to_vec(&bundle).unwrap(),
    )
    .unwrap();
    (root, bundle)
}

#[test]
fn install_upgrade_reuse_and_rollback_keep_complete_bundles() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("custom directory é");
    let (first_source, first) = fixture(temp.path(), "1.2.3");
    let (next_source, next) = fixture(temp.path(), "1.2.4");
    let installed = install_bundle(&first_source, &first, Some(&root)).unwrap();
    assert_eq!(installed.version.as_deref(), Some("1.2.3"));
    assert_eq!(
        fs::read(&installed.executable).unwrap(),
        format!("1.2.3: {}\n", executable()).as_bytes()
    );
    assert!(installed.skill_file.is_file());
    assert!(installed.executable.to_str().unwrap().contains("current"));
    install_bundle(&next_source, &next, Some(&root)).unwrap();
    assert_eq!(
        inspect(Some(&root)).unwrap().version.as_deref(),
        Some("1.2.4")
    );
    first.verify(&root.join("versions/1.2.3")).unwrap();
    install_bundle(&first_source, &first, Some(&root)).unwrap();
    install_bundle(&first_source, &first, Some(&root)).unwrap();
    assert_eq!(
        inspect(Some(&root)).unwrap().version.as_deref(),
        Some("1.2.3")
    );
    next.verify(&root.join("versions/1.2.4")).unwrap();
}

#[test]
fn inspect_does_not_create_directories_or_a_ledger() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("absent");
    let info = inspect(Some(&root)).unwrap();
    assert!(info.version.is_none());
    assert!(!root.exists());
    assert!(
        String::from_utf8(info.output(false).unwrap())
            .unwrap()
            .contains("No active")
    );
}

#[test]
fn concurrent_installation_cannot_publish_a_version_or_change_current() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("install");
    let (source, bundle) = fixture(temp.path(), "1.2.3");
    install_bundle(&source, &bundle, Some(&root)).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .open(root.join(".install.lock"))
        .unwrap();
    lock.try_lock().unwrap();
    let (next_source, next) = fixture(temp.path(), "1.2.4");
    let error = install_bundle(&next_source, &next, Some(&root))
        .err()
        .unwrap();
    assert!(error.to_string().contains("busy"));
    assert!(!root.join("versions/1.2.4").exists());
    assert_eq!(
        inspect(Some(&root)).unwrap().version.as_deref(),
        Some("1.2.3")
    );
}

#[test]
fn changed_or_incomplete_bundle_preserves_current() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("install");
    let (source, first) = fixture(temp.path(), "1.2.3");
    install_bundle(&source, &first, Some(&root)).unwrap();
    let (new_source, next) = fixture(temp.path(), "1.2.4");
    fs::write(new_source.join(SKILL_FILES[1]), "damage").unwrap();
    assert!(install_bundle(&new_source, &next, Some(&root)).is_err());
    assert_eq!(
        inspect(Some(&root)).unwrap().version.as_deref(),
        Some("1.2.3")
    );
    assert!(!root.join("versions/1.2.4").exists());
    fs::remove_file(new_source.join(SKILL_FILES[2])).unwrap();
    assert!(next.verify(&new_source).is_err());
}

#[test]
fn installed_version_is_immutable_and_tampering_is_reported() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("install");
    let (source, bundle) = fixture(temp.path(), "1.2.3");
    install_bundle(&source, &bundle, Some(&root)).unwrap();
    let damaged = root.join("versions/1.2.3/skill/SKILL.md");
    fs::write(&damaged, "user edit").unwrap();
    assert!(install_bundle(&source, &bundle, Some(&root)).is_err());
    assert_eq!(fs::read_to_string(&damaged).unwrap(), "user edit");
    assert!(inspect(Some(&root)).is_err());
}

#[test]
fn unexpected_current_directory_is_not_replaced() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("install");
    fs::create_dir_all(root.join("current")).unwrap();
    fs::write(root.join("current/keep"), "unrelated").unwrap();
    let (source, bundle) = fixture(temp.path(), "1.2.3");
    assert!(install_bundle(&source, &bundle, Some(&root)).is_err());
    assert_eq!(
        fs::read_to_string(root.join("current/keep")).unwrap(),
        "unrelated"
    );
    assert!(!root.join("versions/1.2.3").exists());
}

#[test]
fn interrupted_junction_switch_is_recovered_before_retry() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("install");
    let (source, bundle) = fixture(temp.path(), "1.2.3");
    install_bundle(&source, &bundle, Some(&root)).unwrap();
    fs::rename(root.join("current"), root.join(".previous-current")).unwrap();
    install_bundle(&source, &bundle, Some(&root)).unwrap();
    assert_eq!(
        inspect(Some(&root)).unwrap().version.as_deref(),
        Some("1.2.3")
    );
    assert!(!root.join(".previous-current").exists());
}

#[test]
fn manifest_rejects_traversal_duplicates_and_missing_skill_references() {
    let temp = tempfile::tempdir().unwrap();
    let (_, mut bundle) = fixture(temp.path(), "1.2.3");
    bundle.files[0].name = "../escape".into();
    assert!(bundle.validate().is_err());
    bundle.files[0].name = bundle.files[1].name.clone();
    assert!(bundle.validate().is_err());
    bundle.files.remove(0);
    assert!(bundle.validate().is_err());
}
