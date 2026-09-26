//! Experimental diagnostic executable; deliberately separate from `isled` CLI.
mod fixtures;

use clap::{Parser, ValueEnum};
use isled::{
    cache::Cache,
    filesystem::ProjectRoot,
    graph_layout::{Direction, store},
    issue::Status,
};
use serde::Serialize;
use serde_json::json;
use std::{
    collections::BTreeMap,
    error::Error,
    io::{self, Write},
    path::PathBuf,
    time::Instant,
};

#[derive(Clone, Copy, ValueEnum)]
enum Selection {
    Open,
    Closed,
    All,
}
#[derive(Clone, Copy, ValueEnum)]
enum Order {
    Prerequisites,
    Dependents,
}
#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Text,
    Json,
    None,
}

#[derive(Parser)]
#[command(
    about = "Experimental Rust dependency-layout preview (not a supported isled interface)",
    after_help = "Examples (use a disposable ledger):\n  cargo run --release --example graph-layout -- --root /tmp/ledger --status open\n  cargo run --release --example graph-layout -- --root /tmp/ledger --direction dependents --format json --start 32 --count 32\n  cargo run --release --example graph-layout -- --root /tmp/ledger --synthetic diamonds --nodes 10\n\nText legend: ● issue, │ continuing lane, ┬ branch port, ┼ join, ╪ crossing without a join.\nJSON and cache formats are experimental. Metrics and ledger warnings go to stderr."
)]
struct Args {
    #[arg(long)]
    root: PathBuf,
    #[arg(long, value_enum, default_value = "open")]
    status: Selection,
    #[arg(long, value_enum, default_value = "prerequisites")]
    direction: Order,
    #[arg(long, value_enum, default_value = "text")]
    format: Format,
    /// Zero-based absolute start row.
    #[arg(long, default_value_t = 0)]
    start: usize,
    /// Maximum returned headings; graph preparation always covers all selected nodes.
    #[arg(long, default_value_t = 32)]
    count: usize,
    /// Refuse wider text previews; JSON remains sparse and carries every route.
    #[arg(long, default_value_t = 32)]
    max_lanes: usize,
    /// Provisional candidate work guard, not a production limit.
    #[arg(long, default_value_t = 1_000_000)]
    max_edges: usize,
    /// Provisional per-slot byte budget; six cache slots are retained.
    #[arg(long, default_value_t = 16_777_216)]
    cache_bytes: usize,
    #[arg(long)]
    no_layout_cache: bool,
    /// Reconcile the full ledger before extracting graph metadata.
    #[arg(long)]
    refresh: bool,
    /// Use a deterministic measurement graph instead of ledger metadata.
    #[arg(long, value_enum)]
    synthetic: Option<fixtures::Shape>,
    #[arg(long, default_value_t = 5_000, value_parser = clap::value_parser!(u16).range(1..=9999))]
    nodes: u16,
}

fn main() {
    if let Err(error) = run(Args::parse()) {
        eprintln!("graph-layout: {error}");
        std::process::exit(1);
    }
}

fn run(args: Args) -> Result<(), Box<dyn Error>> {
    let started = Instant::now();
    let root = ProjectRoot::explicit(&args.root)?;
    let lock = root.acquire_lock()?;
    let status = match args.status {
        Selection::Open => Some(Status::Open),
        Selection::Closed => Some(Status::Closed),
        Selection::All => None,
    };
    let direction = match args.direction {
        Order::Prerequisites => Direction::PrerequisitesFirst,
        Order::Dependents => Direction::DependentsFirst,
    };
    let mut labels = BTreeMap::new();
    let mut headings = BTreeMap::new();
    let mut warnings = Vec::new();
    let graph;
    let opened;
    let reads;
    if let Some(shape) = args.synthetic {
        reads = 0;
        opened = started.elapsed();
        graph = fixtures::graph(shape, args.nodes, args.max_edges)?;
        for id in 1..=args.nodes {
            labels.insert(id, format!("{shape:?} task {id}"));
            headings.insert(id, json!({"id":id,"title":labels[&id]}));
        }
    } else {
        lock.read_identities()?;
        let cache = if args.refresh {
            Cache::open_for_refresh(&lock, None)?
        } else {
            Cache::open(&lock)?
        };
        opened = started.elapsed();
        let (summaries, selected) = cache.layout_inputs(status, args.max_edges)?;
        graph = selected;
        warnings.extend_from_slice(cache.warnings());
        reads = cache.files_read();
        for summary in summaries {
            let id = summary.id().get();
            labels.insert(
                id,
                format!(
                    "[{}{}] {}",
                    summary.status().as_str(),
                    if summary.ready() { ", ready" } else { "" },
                    summary.title()
                ),
            );
            headings.insert(id, json!({"id":id,"title":summary.title(),"status":summary.status().as_str(),"ready":summary.ready()}));
        }
    }
    let extracted = started.elapsed();
    let (plan, reuse, stored_bytes) = if args.no_layout_cache {
        (graph.layout(direction)?, "Disabled".to_owned(), 0)
    } else {
        let cached = store::load_or_compute(&lock, &graph, status, direction, args.cache_bytes)?;
        if cached.reuse == store::Reuse::RebuiltInvalid {
            warnings.push("invalid candidate layout cache entry rebuilt".into());
        }
        (
            cached.plan,
            format!("{:?}", cached.reuse),
            cached.stored_bytes,
        )
    };
    let laid_out = started.elapsed();
    lock.finish()?;
    let released = started.elapsed();
    let end = args.start.saturating_add(args.count).min(plan.rows().len());
    let range = plan.range(args.start..end)?;
    let ranged = started.elapsed();
    let output = match args.format {
        Format::None => Vec::new(),
        Format::Text => format!(
            "Experimental {direction:?}: {} issues, {} edges, {} lanes; rows {}..{}\n{}",
            graph.node_count(),
            graph.edge_count(),
            plan.lanes(),
            args.start,
            end,
            range.text(&labels, args.max_lanes)?
        )
        .into_bytes(),
        Format::Json => serde_json::to_vec(&Preview {
            experimental: true,
            direction,
            layout: &range,
            headings: range.rows().iter().map(|row| &headings[&row.id]).collect(),
        })?,
    };
    let encoded = started.elapsed();
    io::stdout().lock().write_all(&output)?;
    for warning in &warnings {
        eprintln!("graph-layout: warning: {warning}");
    }
    let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
    eprintln!(
        "{}",
        json!({"metrics":{
            "nodes":graph.node_count(),"edges":graph.edge_count(),"lanes":plan.lanes(),
            "open_ms":ms(opened),"extract_ms":ms(extracted-opened),"layout_cache_ms":ms(laid_out-extracted),
            "lock_ms":ms(released),"range_ms":ms(ranged-released),"encode_ms":ms(encoded-ranged),
            "total_ms":ms(started.elapsed()),"markdown_reads":reads,"reuse":reuse,"cache_bytes":stored_bytes,
        "output_bytes":output.len(),"returned_rows":range.rows().len(),"warnings":warnings.len(),
        "peak_rss_kib":peak_rss_kib()
        }})
    );
    Ok(())
}

#[derive(Serialize)]
struct Preview<'a> {
    experimental: bool,
    direction: Direction,
    layout: &'a isled::graph_layout::LayoutRange,
    headings: Vec<&'a serde_json::Value>,
}

fn peak_rss_kib() -> Option<usize> {
    // Linux high-water RSS includes extraction, layout, serialization and loaded records.
    std::fs::read_to_string("/proc/self/status")
        .ok()?
        .lines()
        .find_map(|line| {
            line.strip_prefix("VmHWM:")?
                .split_whitespace()
                .next()?
                .parse()
                .ok()
        })
}
