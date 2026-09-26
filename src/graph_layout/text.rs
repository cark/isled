//! Width-bounded diagnostic glyph rendering, separate from logical lane placement.
use super::{LayoutError, LayoutRange};
use std::collections::BTreeMap;

impl LayoutRange {
    /// Diagnostic only: titles are aligned; ╪ is a crossing, ┬/┼ is a join.
    /// Refuse excessive width rather than silently lose dependency information.
    pub fn text(
        &self,
        labels: &BTreeMap<u16, String>,
        max_lanes: usize,
    ) -> Result<String, LayoutError> {
        if self.lanes > max_lanes {
            return Err(LayoutError(format!(
                "layout needs {} lanes; text preview budget is {max_lanes}; use --format json or the flat view",
                self.lanes
            )));
        }
        let width = self.lanes.saturating_mul(2).saturating_sub(1);
        let mut active = BTreeMap::new();
        for entry in &self.entry {
            active.insert(entry.lane, entry.target_row);
        }
        let mut text = String::new();
        if !self.entry.is_empty() {
            text.push_str(&verticals(width, &active));
            text.push_str("  (continues from earlier rows)\n");
        }
        for (offset, row) in self.rows.iter().enumerate() {
            let absolute = self.start + offset;
            let mut gutter: Vec<_> = verticals(width, &active).chars().collect();
            active.retain(|_, target| *target != absolute);
            let (mut left, mut right) = (row.lane, row.lane);
            for route in &row.outgoing {
                left = left.min(route.lane);
                right = right.max(route.lane);
            }
            for cell in &mut gutter[left * 2..=right * 2] {
                *cell = if *cell == '│' { '╪' } else { '─' };
            }
            for route in &row.outgoing {
                gutter[route.lane * 2] = if active.contains_key(&route.lane) {
                    '┼'
                } else {
                    '┬'
                };
                active.insert(route.lane, route.target_row);
            }
            gutter[row.lane * 2] = '●';
            text.extend(gutter);
            text.push_str(&format!(
                "  {:04} {}\n",
                row.id,
                labels.get(&row.id).map_or("", String::as_str)
            ));
            text.push_str(&verticals(width, &active));
            text.push('\n');
        }
        if !self.exit.is_empty() {
            text.push_str("(lanes continue into later rows)\n");
        }
        Ok(text)
    }
}

fn verticals(width: usize, active: &BTreeMap<usize, usize>) -> String {
    let mut cells = vec![' '; width];
    for &lane in active.keys() {
        cells[lane * 2] = '│';
    }
    cells.into_iter().collect()
}
