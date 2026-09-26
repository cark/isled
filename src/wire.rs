//! Shared lossless JSON representation for filesystem byte strings.

use base64::Engine;
use serde::Serialize;
use std::borrow::Cow;

#[derive(Serialize)]
pub struct EncodedBytes<'a> {
    encoding: &'static str,
    value: Cow<'a, str>,
}

impl<'a> EncodedBytes<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        match std::str::from_utf8(bytes) {
            Ok(value) => Self {
                encoding: "utf-8",
                value: Cow::Borrowed(value),
            },
            Err(_) => Self {
                encoding: "base64",
                value: Cow::Owned(base64::engine::general_purpose::STANDARD.encode(bytes)),
            },
        }
    }
}
