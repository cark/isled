//! Sparse range delivery with indexed continuation boundaries.
use super::{LayoutError, Plan};
use serde::Serialize;
use std::ops::Range;

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
pub struct Continuation {
    pub lane: usize,
    pub target_row: usize,
    pub target_id: u16,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
pub struct Route {
    pub target_row: usize,
    pub target_id: u16,
    pub lane: usize,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
pub struct RangeRow {
    pub id: u16,
    pub lane: usize,
    pub outgoing: Vec<Route>,
}

/// Absolute indices and explicit boundary continuations make a range self-contained.
#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
pub struct LayoutRange {
    pub(super) start: usize,
    pub(super) total: usize,
    pub(super) lanes: usize,
    pub(super) entry: Vec<Continuation>,
    pub(super) rows: Vec<RangeRow>,
    pub(super) exit: Vec<Continuation>,
}

impl Plan {
    pub fn range(&self, range: Range<usize>) -> Result<LayoutRange, LayoutError> {
        if range.start > range.end || range.end > self.rows().len() {
            return Err(LayoutError(
                "layout range is outside the selected rows".into(),
            ));
        }
        Ok(LayoutRange {
            start: range.start,
            total: self.rows().len(),
            lanes: self.lanes(),
            entry: self.continuations(range.start),
            rows: self.rows()[range.clone()]
                .iter()
                .map(|row| RangeRow {
                    id: row.id,
                    lane: row.lane,
                    outgoing: row
                        .targets
                        .iter()
                        .map(|&target| Route {
                            target_row: target,
                            target_id: self.rows()[target].id,
                            lane: self.rows()[target].lane,
                        })
                        .collect(),
                })
                .collect(),
            exit: self.continuations(range.end),
        })
    }

    fn continuations(&self, boundary: usize) -> Vec<Continuation> {
        self.lane_tracks
            .iter()
            .enumerate()
            .filter_map(|(lane, tracks)| {
                let index = tracks.partition_point(|&target| target < boundary);
                let &target = tracks.get(index)?;
                (self.rows()[target].start? < boundary).then_some(Continuation {
                    lane,
                    target_row: target,
                    target_id: self.rows()[target].id,
                })
            })
            .collect()
    }
}

impl LayoutRange {
    pub fn rows(&self) -> &[RangeRow] {
        &self.rows
    }
    pub fn entry(&self) -> &[Continuation] {
        &self.entry
    }
    pub fn exit(&self) -> &[Continuation] {
        &self.exit
    }
}
