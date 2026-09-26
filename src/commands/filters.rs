use super::error::AppError;
use super::issue_id::parse_issue_id;
use isled::cli::FilterArgs;
use isled::issue::{Name, Status, Tag};
use isled::query::Filters;

#[derive(Clone, Copy)]
pub(crate) enum StatusDefault {
    Open,
    All,
}

pub(crate) fn parse_filters(
    arguments: FilterArgs,
    default: StatusDefault,
) -> Result<Filters, AppError> {
    if arguments.all && arguments.status.is_some() {
        return Err(AppError::Invocation("use only one status filter".into()));
    }
    if arguments.waiting > 0 && arguments.without_waits > 0 {
        return Err(AppError::Invocation(
            "--waiting conflicts with --without-waits".into(),
        ));
    }
    if arguments.ready && (arguments.all || arguments.status.is_some()) {
        return Err(AppError::Invocation(
            "--ready conflicts with another status filter".into(),
        ));
    }
    if arguments.ready && arguments.waiting > 0 {
        return Err(AppError::Invocation(
            "--ready conflicts with --waiting".into(),
        ));
    }

    let status = if arguments.ready {
        Some(Status::Open)
    } else if arguments.all {
        None
    } else if let Some(value) = arguments.status {
        Some(
            Status::try_parse(value.as_bytes())
                .map_err(|_| AppError::Invocation(format!("invalid status: {value}")))?,
        )
    } else {
        match default {
            StatusDefault::Open => Some(Status::Open),
            StatusDefault::All => None,
        }
    };
    let kind = arguments
        .kind
        .last()
        .map(|value| {
            Name::try_parse(value.as_bytes())
                .map_err(|_| AppError::Invocation(format!("invalid kind: {value}")))
        })
        .transpose()?;
    let mut tags = Vec::new();
    for group in arguments.tags {
        if group.is_empty()
            || group.starts_with(',')
            || group.ends_with(',')
            || group.contains(",,")
        {
            return Err(AppError::Invocation(format!("invalid tag: {group}")));
        }
        for value in group.split(',') {
            let tag = Tag::try_parse(value.as_bytes())
                .map_err(|_| AppError::Invocation(format!("invalid tag: {value}")))?;
            if !tags.iter().any(|existing: &Tag| existing == &tag) {
                tags.push(tag);
            }
        }
    }
    let waiting_on = arguments
        .waiting_on
        .last()
        .map(|value| parse_issue_id(value))
        .transpose()?;
    let waiting = if arguments.ready || arguments.without_waits > 0 {
        Some(false)
    } else if arguments.waiting > 0 {
        Some(true)
    } else {
        None
    };

    Ok(Filters {
        status,
        kind,
        tags,
        waiting,
        waiting_on,
    })
}
