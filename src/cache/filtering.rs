//! Text selection for frontend summaries, without a persistent text index.
use super::{Cache, CacheError, Summary};
use crate::{
    issue::Name,
    query::{Filters, SearchSnippets},
};
use icu_casemap::CaseMapper;

impl Cache<'_> {
    pub(crate) fn filter_summaries(
        &self,
        filters: &Filters,
        kinds: &[Name],
        text: Option<&SearchSnippets>,
    ) -> Result<Vec<Summary>, CacheError> {
        let candidates = self.summaries(filters)?;
        let terms = text.map(|terms| {
            terms
                .iter()
                .map(|term| CaseMapper::new().fold_string(term).into_owned())
                .collect::<Vec<_>>()
        });
        candidates
            .into_iter()
            .filter_map(|row| {
                if !kinds.iter().all(|kind| kind == row.kind()) {
                    return None;
                }
                match &terms {
                    None => Some(Ok(row)),
                    Some(terms) => match self.matches_text(&row, terms) {
                        Ok(true) => Some(Ok(row)),
                        Ok(false) => None,
                        Err(error) => Some(Err(error)),
                    },
                }
            })
            .collect()
    }

    fn matches_text(&self, row: &Summary, terms: &[String]) -> Result<bool, CacheError> {
        let record = self.lock.load_file(row.filename().as_bytes())?.record()?;
        let text =
            std::str::from_utf8(record.bytes()).map_err(|e| CacheError::Invalid(e.to_string()))?;
        let folded = CaseMapper::new().fold_string(text);
        Ok(terms.iter().all(|term| folded.contains(term)))
    }
}
