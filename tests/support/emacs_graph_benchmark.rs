//! Real frontend payloads for isolated Emacs display and cost measurements.
#[path = "../../src/graph_layout/fixtures.rs"]
mod shapes;
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, Stdio},
    time::Instant,
};

pub fn run(root: &Path) -> Result<(), String> {
    let output = std::env::current_dir()
        .unwrap()
        .join("target/graph-frontend-results");
    fs::create_dir_all(&output).unwrap();
    let mut cases = vec![("baseline", root.to_path_buf())];
    for (name, shape) in [
        ("diamonds", shapes::Shape::Diamonds),
        ("wide", shapes::Shape::Fanout),
        ("dense", shapes::Shape::Dense),
    ] {
        let path = root.join(name);
        generate_graph(&path, shape);
        cases.push((name, path));
    }
    let mut manifest = Vec::new();
    let mut metrics = Vec::new();
    for (name, path) in &cases {
        call(path, json!({"schema_version":4,"mode":"refresh"}));
        for direction in [None, Some("prerequisites"), Some("dependents")] {
            let label = format!("{name}-{}", direction.unwrap_or("flat"));
            let mut input = json!({"schema_version":4,"mode":"view","filter":{"status":"all"}});
            if let Some(direction) = direction {
                input["graph"] = json!({"direction":direction});
            }
            let mut times = Vec::new();
            let mut bytes = Vec::new();
            for _ in 0..5 {
                let (ms, data) = call(path, input.clone());
                times.push(ms);
                bytes = data;
            }
            let file = root.join(format!("{label}.json"));
            fs::write(&file, &bytes).unwrap();
            metrics.push(json!({"case":label,"process_ms":times,"bytes":bytes.len()}));
            manifest.push(json!({"name":label,"file":file,"root":path}));
        }
    }
    let (_, details) = call(
        root,
        json!({"schema_version":4,"mode":"details","details":[{"id":"0001"}]}),
    );
    fs::write(root.join("details.json"), details).unwrap();
    fs::write(
        root.join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    fs::write(
        output.join("rust.json"),
        serde_json::to_vec_pretty(&metrics).unwrap(),
    )
    .unwrap();
    let repo = std::env::current_dir().unwrap();
    let status = Command::new("python3")
        .arg(repo.join("scripts/private-graphical-emacs.py"))
        .args([
            "--script",
            "frontends/emacs/test/graph-graphical.el",
            "--load-path",
            "frontends/emacs",
            "--timeout",
            "120",
            "--env",
        ])
        .arg(format!("ISLED_GRAPH_FIXTURE={}", root.display()))
        .arg("--env")
        .arg(format!("ISLED_GRAPH_RESULTS={}", output.display()))
        .status()
        .map_err(|e| e.to_string())?;
    if !status.success() {
        return Err(format!("private graph display check failed: {status}"));
    }
    println!("graph frontend measurements: {}", output.display());
    Ok(())
}

fn call(root: &Path, input: Value) -> (f64, Vec<u8>) {
    let start = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_isled"))
        .arg("--root")
        .arg(root)
        .args(["frontend", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.to_string().as_bytes())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        result.stderr.is_empty(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    (start.elapsed().as_secs_f64() * 1000.0, result.stdout)
}

fn generate_graph(root: &Path, shape: shapes::Shape) {
    let directory = root.join(".issues");
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join(".next-id"), "5001\n").unwrap();
    let graph = shapes::graph(shape, 5000, 1_000_000).unwrap();
    let plan = graph
        .layout(isled::graph_layout::Direction::PrerequisitesFirst)
        .unwrap();
    let mut waiting = vec![Vec::new(); 5001];
    let mut blocking = vec![Vec::new(); 5001];
    for row in plan.rows() {
        for &target in row.targets() {
            let dependent = plan.rows()[target].id().get();
            waiting[usize::from(dependent)].push(row.id().get());
            blocking[usize::from(row.id().get())].push(dependent);
        }
    }
    for id in 1..=5000 {
        let mut record = format!(
            "# {id:04} — Node {id}\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-24\n"
        );
        if !waiting[id].is_empty() {
            record.push_str("- **Waiting on:**\n");
            for &other in &waiting[id] {
                record.push_str(&format!(
                    "  - #{other:04} — Node {other}\n    - **Reason:** Required.\n"
                ));
            }
        }
        if !blocking[id].is_empty() {
            record.push_str("- **Blocking:**\n");
            for &other in &blocking[id] {
                record.push_str(&format!("  - #{other:04} — Node {other}\n"));
            }
        }
        record.push_str("\n## Statement\n\nGraph fixture.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n");
        fs::write(directory.join(format!("{id:04}-node.md")), record).unwrap();
    }
}
