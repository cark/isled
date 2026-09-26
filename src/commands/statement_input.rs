use super::error::AppError;
use std::io::{self, IsTerminal, Read};

pub(crate) fn read_statement_stdin(prompt: &str) -> Result<String, AppError> {
    let mut stdin = io::stdin().lock();
    if stdin.is_terminal() {
        eprintln!("{prompt}");
    }
    let mut text = String::new();
    stdin.read_to_string(&mut text).map_err(AppError::Io)?;
    Ok(text)
}
