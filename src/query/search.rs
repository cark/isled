//! Text search, Unicode matching, and bounded excerpts.

use super::filters::matches_filters;
use super::list::append_summary;
use super::records::{ViewIndex, parse_record_views};
use super::{Filters, OutputPaths, QueryError};
use crate::filesystem::StoredRecord;
use icu_casemap::CaseMapper;
use std::error::Error;
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SearchSnippets(Vec<String>);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ParseSearchSnippetsError {
    Missing,
    Empty,
    Multiline,
}

impl SearchSnippets {
    pub fn parse(values: Vec<String>) -> Result<Self, ParseSearchSnippetsError> {
        if values.is_empty() {
            return Err(ParseSearchSnippetsError::Missing);
        }
        if values.iter().any(String::is_empty) {
            return Err(ParseSearchSnippetsError::Empty);
        }
        if values.iter().any(|value| value.contains('\n')) {
            return Err(ParseSearchSnippetsError::Multiline);
        }
        Ok(Self(values))
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = &str> {
        self.0.iter().map(String::as_str)
    }
}

impl fmt::Display for ParseSearchSnippetsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing => write!(formatter, "search requires at least one snippet"),
            Self::Empty => write!(formatter, "search snippet must be non-empty"),
            Self::Multiline => write!(formatter, "search snippet must be one line"),
        }
    }
}

impl Error for ParseSearchSnippetsError {}
pub fn search_parsed(
    records: &[StoredRecord],
    filters: &Filters,
    snippets: &SearchSnippets,
) -> Result<Vec<u8>, QueryError> {
    search_records(records, filters, snippets, None)
}

pub fn search_parsed_with_paths(
    records: &[StoredRecord],
    filters: &Filters,
    snippets: &SearchSnippets,
    paths: &OutputPaths,
) -> Result<Vec<u8>, QueryError> {
    search_records(records, filters, snippets, Some(paths))
}

fn search_records(
    records: &[StoredRecord],
    filters: &Filters,
    snippets: &SearchSnippets,
    paths: Option<&OutputPaths>,
) -> Result<Vec<u8>, QueryError> {
    let folded_needles = snippets
        .iter()
        .map(|snippet| case_fold(snippet).chars().collect::<Vec<_>>())
        .collect::<Vec<_>>();
    let views = parse_record_views(records)?;
    let index = ViewIndex::new(&views);
    let mut selected_rows = Vec::new();

    for (record, view) in records.iter().zip(views.iter()) {
        if !matches_filters(view, filters, &index)? {
            continue;
        }
        let text = std::str::from_utf8(view.bytes()).map_err(|_| QueryError::InvalidUtf8)?;
        let Some(selected) = select_lines(text, folded_needles.iter().map(Vec::as_slice)) else {
            continue;
        };
        let path = paths
            .map(|value| value.get(record.filename()))
            .transpose()?;
        selected_rows.push((view, selected, path));
    }
    if filters.oldest_first {
        selected_rows.sort_by_key(|(view, _, _)| {
            let since = view.work_state().and_then(|state| state.since());
            (since.is_none(), since, view.id())
        });
    }
    let mut output = Vec::new();
    for (view, lines, path) in selected_rows
        .into_iter()
        .take(filters.limit.unwrap_or(usize::MAX))
    {
        append_summary(&mut output, view, path)?;
        append_selected_lines(&mut output, lines);
    }
    Ok(output)
}

fn select_lines<'a>(
    text: &str,
    needles: impl IntoIterator<Item = &'a [char]>,
) -> Option<Vec<SelectedLine>> {
    let mut selected = Vec::new();
    for needle in needles {
        let found = first_match(text.split_terminator('\n'), needle)?;
        if !selected
            .iter()
            .any(|line: &SelectedLine| line.number == found.number)
        {
            selected.push(found);
        }
    }
    Some(selected)
}

fn append_selected_lines(output: &mut Vec<u8>, lines: impl IntoIterator<Item = SelectedLine>) {
    for line in lines {
        output.extend_from_slice(format!("  {}: {}\n", line.number, line.excerpt).as_bytes());
    }
}

#[derive(Debug)]
struct SelectedLine {
    number: usize,
    excerpt: String,
}

fn first_match<'a>(
    lines: impl IntoIterator<Item = &'a str>,
    needle: &[char],
) -> Option<SelectedLine> {
    for (line_index, line) in lines.into_iter().enumerate() {
        let (folded, map) = folded_with_map(line);
        let Some(start) = folded
            .windows(needle.len())
            .position(|window| window == needle)
        else {
            continue;
        };
        let end = start + needle.len() - 1;
        return Some(SelectedLine {
            number: line_index + 1,
            excerpt: excerpt(line, map[start], map[end]),
        });
    }
    None
}

fn folded_with_map(text: &str) -> (Vec<char>, Vec<usize>) {
    let mapper = CaseMapper::new();
    let mut folded = Vec::new();
    let mut map = Vec::new();
    let mut utf8 = [0; 4];
    for (index, character) in text.chars().enumerate() {
        for folded_character in mapper.fold_string(character.encode_utf8(&mut utf8)).chars() {
            folded.push(folded_character);
            map.push(index);
        }
    }
    (folded, map)
}

fn case_fold(text: &str) -> String {
    CaseMapper::new().fold_string(text).into_owned()
}

fn excerpt(line: &str, match_start: usize, match_end: usize) -> String {
    let characters = line.chars().collect::<Vec<_>>();
    if characters.len() <= 200 {
        return line.to_owned();
    }
    let width = 198;
    let center = (match_start + match_end + 1) as f64 / 2.0;
    let mut start = (center - width as f64 / 2.0).trunc().max(0.0) as usize;
    start = start.min(characters.len() - width);
    let mut result = String::new();
    if start > 0 {
        result.push('…');
    }
    result.extend(&characters[start..start + width]);
    if start + width < characters.len() {
        result.push('…');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_snippets_retain_collection_and_line_invariants() {
        let snippets = SearchSnippets::parse(vec!["first".into(), "second ✓".into()])
            .expect("valid search snippets");
        assert_eq!(snippets.iter().collect::<Vec<_>>(), ["first", "second ✓"]);
        assert_eq!(
            SearchSnippets::parse(Vec::new()),
            Err(ParseSearchSnippetsError::Missing)
        );
        assert_eq!(
            SearchSnippets::parse(vec![String::new()]),
            Err(ParseSearchSnippetsError::Empty)
        );
        assert_eq!(
            SearchSnippets::parse(vec!["two\nlines".into()]),
            Err(ParseSearchSnippetsError::Multiline)
        );
    }

    #[test]
    fn full_case_folding_matches_expanding_characters() {
        let lines = ["Café résumé Straße"];
        let needle = case_fold("STRASSE").chars().collect::<Vec<_>>();
        let selected = first_match(lines, &needle).unwrap();
        assert_eq!(selected.excerpt, lines[0]);
    }

    #[test]
    fn search_keeps_line_coordinates_and_carriage_returns() {
        let first = case_fold("first").chars().collect::<Vec<_>>();
        let last = case_fold("last").chars().collect::<Vec<_>>();
        for text in ["first\r\n\nlast", "first\r\n\nlast\n"] {
            let selected = select_lines(text, [last.as_slice(), first.as_slice()]).unwrap();
            assert_eq!(selected[0].number, 3);
            assert_eq!(selected[0].excerpt, "last");
            assert_eq!(selected[1].number, 1);
            assert_eq!(selected[1].excerpt, "first\r");
        }
    }

    #[test]
    fn long_excerpt_is_centered_and_bounded() {
        let line = format!("{}Needle{}", "x".repeat(110), "y".repeat(110));
        let needle = case_fold("needle").chars().collect::<Vec<_>>();
        let selected = first_match([line.as_str()], &needle).unwrap();
        assert!(selected.excerpt.starts_with('…'));
        assert!(selected.excerpt.ends_with('…'));
        assert!(selected.excerpt.contains("Needle"));
        assert!(selected.excerpt.chars().count() <= 200);
    }
}
