use super::super::cached_read::with_cached_query;
use super::super::error::AppError;
use super::super::issue_id::parse_issue_id;
use isled::filesystem::{FilesystemError, ProjectRoot};
use isled::query::{OutputPaths, dependency::Direction};

pub(super) fn run(
    arguments: isled::cli::WaitTreeArgs,
    root: impl FnOnce() -> Result<ProjectRoot, FilesystemError>,
) -> Result<Vec<u8>, AppError> {
    let id = parse_issue_id(&arguments.id)?;
    let direction = if arguments.dependents {
        Direction::Dependents
    } else {
        Direction::Dependencies
    };
    let project = root()?;
    with_cached_query(&project, |cache| {
        cache.refresh(Some(id))?;
        let tree = cache.dependency_tree(id, direction)?;
        let paths = arguments
            .with_path
            .then(|| {
                tree.filenames()
                    .map(|name| {
                        Ok((
                            name.to_vec(),
                            if arguments.json {
                                project.issue_path_bytes_lossless(name)?
                            } else {
                                project.issue_path_bytes(name)?
                            },
                        ))
                    })
                    .collect::<Result<Vec<_>, FilesystemError>>()
                    .map(OutputPaths::new)
            })
            .transpose()?;
        if arguments.json {
            Ok(tree.render_json(paths.as_ref())?)
        } else {
            Ok(tree.render_human(paths.as_ref())?)
        }
    })
}
