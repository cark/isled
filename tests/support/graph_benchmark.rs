//! Process-level candidate measurements; all mutation and cache cleanup is disposable.
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Instant,
};

const RUNS: usize = 5;

pub fn run(root: &Path) {
    let preview = std::env::var_os("ISLED_GRAPH_PREVIEW")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("target/release/examples/graph-layout"));
    assert!(
        preview.is_file(),
        "build cargo build --release --example graph-layout first"
    );
    let bench = Bench { root, preview };
    println!(
        "measurement: 5 process samples per case; newly written fixture, warm OS pages, not cold-disk measurements; RSS is Linux VmHWM; times in ms"
    );
    let build = bench.cli(&["cache", "refresh"], None);
    println!(
        "{}",
        json!({"case":"ledger-initial-cache-build","elapsed_ms":build.0})
    );
    for status in ["open", "all"] {
        let input =
            format!(r#"{{"schema_version":4,"mode":"view","filter":{{"status":"{status}"}}}}"#);
        let samples: Vec<_> = (0..RUNS)
            .map(|_| {
                let (ms, bytes) = bench.cli(&["frontend", "--stdin"], Some(input.as_bytes()));
                json!({"process_ms":ms,"output_bytes":bytes.len()})
            })
            .collect();
        report(&format!("flat-{status}"), &samples);
        let args = ["--status", status, "--format", "json", "--count", "9999"];
        bench.measure(&format!("ledger-{status}-uncached"), &args, true, true);
        bench.measure(&format!("ledger-{status}-miss"), &args, true, false);
        bench.measure(&format!("ledger-{status}-hit"), &args, false, false);
    }
    bench.measure(
        "ledger-all-range-hit",
        &[
            "--status", "all", "--format", "json", "--start", "2500", "--count", "32",
        ],
        false,
        false,
    );
    bench.measure(
        "ledger-all-refresh-hit",
        &["--status", "all", "--format", "none", "--refresh"],
        false,
        false,
    );
    for case in ["prose", "topology"] {
        let mut samples = Vec::new();
        bench.preview(&["--status", "all", "--format", "none"], false);
        for _ in 0..RUNS {
            let mutation = if case == "prose" {
                bench
                    .cli(
                        &["statement", "append", "4500", "Candidate measurement."],
                        None,
                    )
                    .0
            } else {
                bench
                    .cli(
                        &["wait", "add", "4500", "4501", "Candidate measurement."],
                        None,
                    )
                    .0
            };
            let mut sample = bench.preview(&["--status", "all", "--format", "none"], false);
            sample["mutation_cli_ms"] = json!(mutation);
            assert_eq!(
                sample["reuse"],
                if case == "prose" { "Hit" } else { "Miss" }
            );
            samples.push(sample);
            if case == "topology" {
                bench.cli(&["wait", "remove", "4500", "4501"], None);
                bench.preview(&["--status", "all", "--format", "none"], false);
            }
        }
        report(&format!("ledger-{case}-update"), &samples);
    }
    for shape in [
        "short-chains",
        "chain",
        "fanout",
        "fanin",
        "diamonds",
        "joins",
        "long-spans",
        "dense",
    ] {
        for direction in ["prerequisites", "dependents"] {
            let base = [
                "--synthetic",
                shape,
                "--nodes",
                "5000",
                "--direction",
                direction,
                "--status",
                "all",
                "--format",
                "json",
                "--count",
                "9999",
            ];
            let name = format!("{shape}-{direction}");
            bench.measure(&format!("{name}-uncached"), &base, true, true);
            bench.measure(&format!("{name}-miss"), &base, true, false);
            bench.measure(&format!("{name}-hit"), &base, false, false);
            let mut range = base.to_vec();
            range.extend(["--start", "2500"]);
            range[11] = "32";
            bench.measure(&format!("{name}-range-hit"), &range, false, false);
        }
    }
    // Keep both orientations, then measure switching between their retained slots.
    bench.preview(
        &[
            "--status",
            "all",
            "--direction",
            "prerequisites",
            "--format",
            "none",
        ],
        false,
    );
    bench.preview(
        &[
            "--status",
            "all",
            "--direction",
            "dependents",
            "--format",
            "none",
        ],
        false,
    );
    let mut samples = Vec::new();
    for _ in 0..RUNS {
        for direction in ["prerequisites", "dependents"] {
            let sample = bench.preview(
                &[
                    "--status",
                    "all",
                    "--direction",
                    direction,
                    "--format",
                    "none",
                ],
                false,
            );
            assert_eq!(sample["reuse"], "Hit");
            samples.push(sample);
        }
    }
    report("ledger-direction-switch-hit", &samples);
}

struct Bench<'a> {
    root: &'a Path,
    preview: PathBuf,
}

impl Bench<'_> {
    fn cli(&self, args: &[&str], input: Option<&[u8]>) -> (f64, Vec<u8>) {
        let started = Instant::now();
        let mut child = Command::new(env!("CARGO_BIN_EXE_isled"))
            .arg("--root")
            .arg(self.root)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        if let Some(input) = input {
            child.stdin.take().unwrap().write_all(input).unwrap();
        } else {
            drop(child.stdin.take());
        }
        let output = child.wait_with_output().unwrap();
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
        (started.elapsed().as_secs_f64() * 1000.0, output.stdout)
    }

    fn preview(&self, args: &[&str], no_cache: bool) -> Value {
        let started = Instant::now();
        let mut command = Command::new(&self.preview);
        command.arg("--root").arg(self.root).args(args);
        if no_cache {
            command.arg("--no-layout-cache");
        }
        let output = command.output().unwrap();
        let elapsed = started.elapsed().as_secs_f64() * 1000.0;
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert_eq!(stderr.lines().count(), 1, "unexpected warning: {stderr}");
        let mut value: Value = serde_json::from_str(&stderr).unwrap();
        let mut metrics = value["metrics"].take();
        assert_eq!(metrics["output_bytes"], output.stdout.len());
        metrics["process_ms"] = json!(elapsed);
        if let Ok(payload) = serde_json::from_slice::<Value>(&output.stdout) {
            metrics["layout_json_bytes"] =
                json!(serde_json::to_vec(&payload["layout"]).unwrap().len());
        }
        metrics
    }

    fn measure(&self, name: &str, args: &[&str], clear: bool, no_cache: bool) {
        let mut samples = Vec::new();
        for _ in 0..RUNS {
            if clear {
                let cache = self.root.join(".issues/.cache/graph-layout-candidate");
                if cache.exists() {
                    fs::remove_dir_all(cache).unwrap();
                }
            }
            let sample = self.preview(args, no_cache);
            assert_eq!(
                sample["markdown_reads"],
                if args.contains(&"--refresh") { 5000 } else { 0 }
            );
            assert_eq!(
                sample["reuse"],
                if no_cache {
                    "Disabled"
                } else if clear {
                    "Miss"
                } else {
                    "Hit"
                }
            );
            samples.push(sample);
        }
        report(name, &samples);
    }
}

fn report(name: &str, samples: &[Value]) {
    let mut median = serde_json::Map::new();
    let mut maximum = serde_json::Map::new();
    for key in samples[0].as_object().unwrap().keys() {
        let mut values: Vec<_> = samples.iter().filter_map(|s| s[key].as_f64()).collect();
        if values.is_empty() {
            continue;
        }
        values.sort_by(f64::total_cmp);
        median.insert(key.clone(), json!(values[values.len() / 2]));
        maximum.insert(key.clone(), json!(values[values.len() - 1]));
    }
    println!(
        "{}",
        json!({"case":name,"samples":samples.len(),"median":median,"max":maximum})
    );
}
