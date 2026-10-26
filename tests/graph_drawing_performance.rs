//! Isolate ordering, physical route planning and encoding from ledger/process I/O.
#[path = "../src/graph_layout/fixtures.rs"]
mod shapes;
use isled::graph_layout::Direction;
use serde_json::json;
use std::{hint::black_box, time::Instant};

#[test]
#[ignore = "manual release-mode sparse drawing measurements"]
#[allow(clippy::assertions_on_constants)]
fn sparse_drawing_costs() {
    assert!(!cfg!(debug_assertions), "run with cargo test --release");
    for shape in [
        shapes::Shape::ShortChains,
        shapes::Shape::Chain,
        shapes::Shape::Fanout,
        shapes::Shape::Fanin,
        shapes::Shape::Diamonds,
        shapes::Shape::Joins,
        shapes::Shape::LongSpans,
        shapes::Shape::Dense,
    ] {
        let graph = shapes::graph(shape, 5000, 1_000_000).unwrap();
        for direction in [Direction::PrerequisitesFirst, Direction::DependentsFirst] {
            let mut samples = Vec::new();
            let mut bytes = Vec::new();
            for _ in 0..5 {
                let start = Instant::now();
                let plan = black_box(graph.layout(direction).unwrap());
                let ordered = start.elapsed();
                let drawing = black_box(plan.drawing());
                let drawn = start.elapsed();
                bytes = black_box(serde_json::to_vec(&drawing).unwrap());
                let encoded = start.elapsed();
                let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
                samples.push(json!({"order_ms":ms(ordered),"drawing_ms":ms(drawn-ordered),"encode_ms":ms(encoded-drawn)}));
            }
            let wire: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            println!(
                "{}",
                json!({"shape":format!("{shape:?}"),"direction":format!("{direction:?}"),
                "nodes":graph.node_count(),"edges":graph.edge_count(),"lanes":wire["lanes"],
                "drawing_bytes":bytes.len(),"samples":samples})
            );
        }
    }
}
