use crate::issue::IssueId;
use crate::record::IssueRecord;
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HighWater(u16);

impl HighWater {
    pub const MAX: u16 = 10_000;

    pub fn parse(bytes: &[u8]) -> Result<Self, LedgerError> {
        let line = bytes.strip_suffix(b"\n").unwrap_or(bytes);
        if line.is_empty() || line.contains(&b'\n') || !line.iter().all(u8::is_ascii_digit) {
            return Err(LedgerError::InvalidHighWater);
        }
        let text = std::str::from_utf8(line).map_err(|_| LedgerError::InvalidHighWater)?;
        let value = text
            .parse::<u16>()
            .map_err(|_| LedgerError::InvalidHighWater)?;
        if !(1..=Self::MAX).contains(&value) {
            return Err(LedgerError::InvalidHighWater);
        }
        Ok(Self(value))
    }

    pub fn get(self) -> u16 {
        self.0
    }
}

#[derive(Debug)]
pub struct Ledger {
    records: BTreeMap<IssueId, IssueRecord>,
    high_water: HighWater,
}

impl Ledger {
    pub fn new(
        records: impl IntoIterator<Item = IssueRecord>,
        high_water: HighWater,
    ) -> Result<Self, LedgerError> {
        let mut indexed = BTreeMap::new();
        for record in records {
            let id = record.issue().id;
            if indexed.insert(id, record).is_some() {
                return Err(LedgerError::DuplicateId(id));
            }
        }
        Ok(Self {
            records: indexed,
            high_water,
        })
    }

    pub fn records(&self) -> &BTreeMap<IssueId, IssueRecord> {
        &self.records
    }

    pub fn high_water(&self) -> HighWater {
        self.high_water
    }

    /// Mirrors Bash allocation: stale state is reconciled against the greatest ID.
    pub fn next_id(&self) -> Result<IssueId, LedgerError> {
        let after_maximum = self
            .records
            .last_key_value()
            .map_or(1, |(id, _)| id.get() + 1);
        let next = self.high_water.get().max(after_maximum);
        IssueId::new(next).ok_or(LedgerError::IdSpaceExhausted)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LedgerError {
    InvalidHighWater,
    DuplicateId(IssueId),
    IdSpaceExhausted,
}

impl fmt::Display for LedgerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidHighWater => write!(formatter, "invalid next-ID state"),
            Self::DuplicateId(id) => write!(formatter, "multiple issue files found for {id}"),
            Self::IdSpaceExhausted => write!(formatter, "issue ID space is exhausted"),
        }
    }
}

impl Error for LedgerError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(id: u16, slug: &str) -> IssueRecord {
        let id = format!("{id:04}");
        let filename = format!("{id}-{slug}.md");
        let bytes = format!(
            "# {id} — Example\n\n## Metadata\n\n- **Status:** open\n- **Kind:** feature\n- **Created:** 2026-09-02\n\n## Statement\n\nStatement.\n\n## Evidence\n\n- Pending.\n\n## Outcome\n\nPending.\n"
        );
        IssueRecord::parse(filename.as_bytes(), bytes.into_bytes()).unwrap()
    }

    #[test]
    fn high_water_accepts_leading_zeroes_and_one_optional_newline() {
        assert_eq!(HighWater::parse(b"0008\n").unwrap().get(), 8);
        assert_eq!(HighWater::parse(b"8").unwrap().get(), 8);
        for invalid in [b"0\n".as_slice(), b"10001\n", b"5\n6\n", b"\n"] {
            assert_eq!(
                HighWater::parse(invalid),
                Err(LedgerError::InvalidHighWater)
            );
        }
    }

    #[test]
    fn allocation_reconciles_stale_high_water() {
        let ledger =
            Ledger::new([parsed(8, "highest")], HighWater::parse(b"1\n").unwrap()).unwrap();
        assert_eq!(ledger.next_id().unwrap().get(), 9);
    }

    #[test]
    fn duplicate_stable_ids_are_rejected() {
        let result = Ledger::new(
            [parsed(1, "first"), parsed(1, "second")],
            HighWater::parse(b"2\n").unwrap(),
        );
        assert!(matches!(result, Err(LedgerError::DuplicateId(_))));
    }
}
