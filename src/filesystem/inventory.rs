//! Directory entries retained for one locked operation, invalidated by creation.
use super::{FilesystemError, ProjectRoot};
use std::{cell::RefCell, fs::DirEntry, rc::Rc};

#[derive(Default)]
pub(super) struct Inventory {
    entries: RefCell<Option<Rc<Vec<DirEntry>>>>,
}

impl Inventory {
    pub(super) fn entries(&self, root: &ProjectRoot) -> Result<Rc<Vec<DirEntry>>, FilesystemError> {
        if let Some(entries) = self.entries.borrow().as_ref() {
            return Ok(Rc::clone(entries));
        }
        let entries = Rc::new(root.issue_entries()?);
        *self.entries.borrow_mut() = Some(Rc::clone(&entries));
        Ok(entries)
    }

    pub(super) fn invalidate(&self) {
        self.entries.borrow_mut().take();
    }
}
