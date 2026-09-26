//! Opt-in ballpark timings. Never touches a live ledger or runs by default.
use isled::{
    check,
    filesystem::ProjectRoot,
    record::RecordView,
    snapshot::{Snapshot, SnapshotSource, json},
};
use std::{collections::BTreeMap, fs, hint::black_box, time::Instant};

const ISSUES: usize = 5_000;
const RUNS: usize = 5;

#[path = "support/emacs_graph_benchmark.rs"]
mod emacs_graph_benchmark;
#[path = "support/graph_benchmark.rs"]
mod graph_benchmark;

#[test]
#[ignore = "manual release-mode graph frontend and private display measurements"]
#[allow(clippy::assertions_on_constants)]
fn emacs_graph_frontend() {
    assert!(!cfg!(debug_assertions), "run with cargo test --release");
    let directory = tempfile::tempdir().unwrap();
    generate(directory.path());
    if let Err(error) = emacs_graph_benchmark::run(directory.path()) {
        panic!("{error}; retained fixture: {}", directory.keep().display());
    }
}

#[test]
#[ignore = "manual release-mode candidate graph measurements; build the graph-layout example first"]
#[allow(clippy::assertions_on_constants)]
fn rust_graph_layout_candidate() {
    assert!(!cfg!(debug_assertions), "run with cargo test --release");
    let directory = tempfile::tempdir().unwrap();
    generate(directory.path());
    graph_benchmark::run(directory.path());
}

fn title(id: usize) -> String {
    format!("Component {}: task {id} — café", id % 20)
}

fn generate(root: &std::path::Path) -> usize {
    let directory = root.join(".issues");
    fs::create_dir(&directory).unwrap();
    fs::write(directory.join(".next-id"), format!("{}\n", ISSUES + 1)).unwrap();
    let domains = [
        "rust", "emacs", "cli", "storage", "docs", "testing", "ui", "build",
    ];
    let kinds = ["feature", "maintenance", "bug", "usability"];
    let components = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
        "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon",
    ];
    let mut total = 0;
    for id in 1..=ISSUES {
        let status = if id <= 4_000 { "closed" } else { "open" };
        let mut record = format!(
            "# {id:04} — {}\n\n## Metadata\n\n- **Status:** {status}\n- **Kind:** {}\n- **Created:** 2026-09-05\n- **Tags:** {}, {}, component-{}\n",
            title(id),
            kinds[id % 4],
            domains[id % 8],
            kinds[id % 4],
            components[id % 20]
        );
        // Disjoint five-issue chains: 4000 reasoned, mirrored edges, no cycles.
        if id % 5 != 1 {
            record.push_str(&format!(
                "- **Waiting on:**\n  - #{:04} — {}\n    - **Reason:** Needed before this task.\n",
                id - 1,
                title(id - 1)
            ));
        }
        if id % 5 != 0 {
            record.push_str(&format!(
                "- **Blocking:**\n  - #{:04} — {}\n",
                id + 1,
                title(id + 1)
            ));
        }
        record.push_str("\n## Statement\n\n### Background\n\n");
        for paragraph in 0..6 + id % 12 {
            record.push_str(&format!("Task {id}, paragraph {paragraph}: keep the implementation straightforward, preserve authored text, and verify behavior with representative local data.\n\n"));
        }
        record.push_str("### Notes\n\n- Review #0001 and [the documentation](../README.md).\n- Preserve Unicode such as café and naïve.\n\n## Evidence\n\n- Verified using deterministic fixtures.\n\n## Outcome\n\n");
        record.push_str(if status == "closed" {
            "Implemented and checked.\n"
        } else {
            "Pending.\n"
        });
        total += record.len();
        fs::write(directory.join(format!("{id:04}-generated.md")), record).unwrap();
    }
    total
}

#[test]
#[ignore = "manual release-mode Rust performance experiment; generates 5000 temporary files"]
// Runtime refusal keeps this ignored test compilable in normal debug suites.
#[allow(clippy::assertions_on_constants)]
fn rust_large_ledger_ballpark() {
    assert!(!cfg!(debug_assertions), "run with cargo test --release");
    let parent = std::env::current_dir().unwrap().join("target");
    fs::create_dir_all(&parent).unwrap();
    let directory = tempfile::Builder::new()
        .prefix("ledger-perf-")
        .tempdir_in(&parent)
        .unwrap();
    let bytes = generate(directory.path());
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    println!(
        "fixture issues={ISSUES} closed=4000 open=1000 edges=4000 tag_occurrences=15000 record_bytes={bytes}"
    );
    println!("cache: newly written files; first measured runs are NOT cold-cache measurements");
    println!("mode\trun\tread_ms\tprocess_ms\tencode_ms\ttotal_ms\tinput_bytes\toutput_bytes");
    let mut expected_tags = None;
    // Alternate order so no path always gets the earliest read in a round.
    for run in 1..=RUNS {
        for mode in if run % 2 == 1 {
            ["headers", "snapshot"]
        } else {
            ["snapshot", "headers"]
        } {
            let start = Instant::now();
            if mode == "headers" {
                let headers = root.read_headers().unwrap();
                let read = start.elapsed();
                let input_bytes: usize = headers.iter().map(|header| header.bytes().len()).sum();
                let mut tags = BTreeMap::<String, usize>::new();
                let mut identities = std::collections::BTreeSet::new();
                for header in &headers {
                    let view = RecordView::new(header.filename(), header.bytes()).unwrap();
                    assert!(identities.insert(view.id()), "duplicate issue ID");
                    for tag in view.tags() {
                        *tags.entry(tag.as_str().to_owned()).or_default() += 1;
                    }
                }
                let total = start.elapsed();
                assert_eq!(identities.len(), ISSUES);
                assert_eq!(tags.len(), 32);
                assert_eq!(tags.values().sum::<usize>(), ISSUES * 3);
                if let Some(expected) = &expected_tags {
                    assert_eq!(&tags, expected);
                }
                expected_tags = Some(tags);
                println!(
                    "headers\t{run}\t{:.3}\t{:.3}\t0.000\t{:.3}\t{input_bytes}\t0",
                    read.as_secs_f64() * 1000.0,
                    (total - read).as_secs_f64() * 1000.0,
                    total.as_secs_f64() * 1000.0
                );
                black_box(&expected_tags);
            } else {
                let records = root.read_records().unwrap();
                let paths = records
                    .iter()
                    .map(|record| root.issue_path_bytes_lossless(record.filename()).unwrap())
                    .collect::<Vec<_>>();
                let sources = records
                    .iter()
                    .zip(&paths)
                    .map(|(record, path)| SnapshotSource::record(record, path))
                    .collect::<Vec<_>>();
                let read = start.elapsed();
                let snapshot =
                    Snapshot::build(root.path_bytes_lossless().unwrap(), &sources).unwrap();
                let built = start.elapsed();
                let encoded = json::render(&snapshot).unwrap();
                let total = start.elapsed();
                assert_eq!(snapshot.issues().len(), ISSUES);
                println!(
                    "snapshot\t{run}\t{:.3}\t{:.3}\t{:.3}\t{:.3}\t{bytes}\t{}",
                    read.as_secs_f64() * 1000.0,
                    (built - read).as_secs_f64() * 1000.0,
                    (total - built).as_secs_f64() * 1000.0,
                    total.as_secs_f64() * 1000.0,
                    encoded.len()
                );
                black_box(encoded);
            }
        }
    }
    // Full integrity audit is separate, not a hidden prewarming step.
    let start = Instant::now();
    let audit = root.audit_snapshot().unwrap();
    let read = start.elapsed();
    let report = check::audit(&audit);
    assert!(
        !report.has_findings(),
        "{}",
        String::from_utf8_lossy(&report.render())
    );
    println!(
        "check read_ms={:.3} total_ms={:.3} findings=0",
        read.as_secs_f64() * 1000.0,
        start.elapsed().as_secs_f64() * 1000.0
    );
    println!("tag_counts={:?}", expected_tags.unwrap());
    directory.close().unwrap();
    println!("fixture_removed=true");
}

#[test]
#[ignore = "manual release-mode cache and CLI timings on 5000 generated files"]
#[allow(clippy::assertions_on_constants)]
fn rust_cache_ballpark() {
    use isled::{cache::Cache, query::Filters};
    use std::process::Command;
    assert!(!cfg!(debug_assertions), "run with cargo test --release");
    let parent = std::env::current_dir().unwrap().join("target");
    fs::create_dir_all(&parent).unwrap();
    let directory = tempfile::Builder::new()
        .prefix("cache-perf-")
        .tempdir_in(parent)
        .unwrap();
    let bytes = generate(directory.path());
    let root = ProjectRoot::explicit(directory.path()).unwrap();
    let command = |args: &[&str]| {
        let start = Instant::now();
        let output = Command::new(env!("CARGO_BIN_EXE_isled"))
            .arg("--root")
            .arg(directory.path())
            .args(args)
            .output()
            .unwrap();
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            output.stderr.is_empty(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        (elapsed, output.stdout)
    };
    println!(
        "fixture issues=5000 edges=4000 record_bytes={bytes}; newly written files, not cold OS cache; CLI timings include startup/output capture"
    );
    let (ms, output) = command(&["list"]);
    assert_eq!(output.split(|b| *b == b'\n').count() - 1, 1000);
    println!(
        "first_cache_build_cli_ms={ms:.3} output_bytes={}",
        output.len()
    );
    for args in [
        vec!["list"],
        vec!["list", "--ready"],
        vec!["list", "--tags", "rust"],
        vec!["path", "4500"],
        vec!["show", "4500"],
        vec!["wait", "tree", "4500", "--json"],
        vec!["cache", "refresh", "4500"],
        vec!["cache", "refresh"],
    ] {
        let mut samples = Vec::new();
        let mut output_bytes = 0;
        for _ in 0..RUNS {
            let (ms, output) = command(&args);
            samples.push(ms);
            output_bytes = output.len();
        }
        samples.sort_by(f64::total_cmp);
        println!(
            "cli={args:?} n={RUNS} median_ms={:.3} max_ms={:.3} output_bytes={output_bytes}",
            samples[RUNS / 2],
            samples[RUNS - 1]
        );
    }
    let mut mutation = Vec::new();
    for _ in 0..RUNS {
        mutation.push(command(&["tag", "add", "4500", "perf-test"]).0);
        command(&["tag", "remove", "4500", "perf-test"]);
    }
    mutation.sort_by(f64::total_cmp);
    println!(
        "tag_mutation_and_sync n={RUNS} median_ms={:.3} max_ms={:.3}",
        mutation[RUNS / 2],
        mutation[RUNS - 1]
    );
    let start = Instant::now();
    let names = fs::read_dir(root.issues_dir())
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    let enumeration = start.elapsed();
    for entry in &names {
        black_box(entry.metadata().unwrap());
    }
    println!(
        "enumeration_ms={:.3} per_entry_metadata_ms={:.3}",
        enumeration.as_secs_f64() * 1000.0,
        (start.elapsed() - enumeration).as_secs_f64() * 1000.0
    );
    {
        let lock = root.acquire_lock().unwrap();
        let start = Instant::now();
        let cache = Cache::open(&lock).unwrap();
        let opened = start.elapsed();
        let tags = cache.tag_counts().unwrap();
        assert_eq!(tags.len(), 32);
        assert_eq!(tags.iter().map(|(_, n)| n).sum::<u32>(), 15000);
        assert_eq!(cache.files_read(), 0);
        assert_eq!(cache.summaries(&Filters::default()).unwrap().len(), 5000);
        println!(
            "warm_open_ms={:.3} tags_and_all_summaries_ms={:.3} markdown_reads=0",
            opened.as_secs_f64() * 1000.0,
            (start.elapsed() - opened).as_secs_f64() * 1000.0
        );
    }
    let extra = root.issues_dir().join("5001-extra.md");
    // Use the production CLI to create an independent, valid extra record.
    let (created, _) = command(&[
        "add",
        "Extra",
        "Performance membership test.",
        "--kind",
        "maintenance",
        "--slug",
        "extra",
    ]);
    assert!(extra.is_file());
    fs::remove_file(&extra).unwrap();
    let (removed, _) = command(&["list"]);
    println!("create_and_sync_ms={created:.3} external_removal_query_ms={removed:.3}");
    assert!(run_audit(&root));
    directory.close().unwrap();
    println!("fixture_removed=true");
}

fn run_audit(root: &ProjectRoot) -> bool {
    let report = check::audit(&root.audit_snapshot().unwrap());
    assert!(
        !report.has_findings(),
        "{}",
        String::from_utf8_lossy(&report.render())
    );
    true
}
