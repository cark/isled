//! Resumable UTC work spans, with chronological and single-clock invariants.
use chrono::{NaiveDateTime, Utc};
use std::{fmt, str::FromStr};

const FORMAT: &str = "%Y-%m-%d %H:%M:%S";

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct WorkTime(i64);
impl WorkTime {
    pub fn now() -> Self {
        Self(Utc::now().timestamp())
    }
    pub fn seconds_since(self, start: Self) -> u64 {
        self.0.saturating_sub(start.0).max(0).cast_unsigned()
    }
}
impl FromStr for WorkTime {
    type Err = WorkLogError;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let time = NaiveDateTime::parse_from_str(value, FORMAT).map_err(|_| WorkLogError::Time)?;
        if time.format(FORMAT).to_string() != value
            || value.len() != 19
            || time.and_utc().timestamp_subsec_nanos() != 0
        {
            return Err(WorkLogError::Time);
        }
        Ok(Self(time.and_utc().timestamp()))
    }
}
impl fmt::Display for WorkTime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            chrono::DateTime::from_timestamp(self.0, 0)
                .expect("valid work time")
                .format(FORMAT)
        )
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct WorkActivity(String);
impl WorkActivity {
    pub fn parse(value: &str) -> Result<Self, WorkLogError> {
        if value.contains(['\n', '\r', '\0', '|']) || value.trim() != value {
            return Err(WorkLogError::Activity);
        }
        Ok(Self(value.into()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkSpan {
    started: WorkTime,
    stopped: Option<WorkTime>,
    activity: WorkActivity,
}
impl WorkSpan {
    pub fn new(
        started: WorkTime,
        stopped: Option<WorkTime>,
        activity: WorkActivity,
    ) -> Result<Self, WorkLogError> {
        if stopped.is_some_and(|end| end < started) {
            return Err(WorkLogError::Order);
        }
        Ok(Self {
            started,
            stopped,
            activity,
        })
    }
    pub fn started(&self) -> WorkTime {
        self.started
    }
    pub fn stopped(&self) -> Option<WorkTime> {
        self.stopped
    }
    pub fn activity(&self) -> &WorkActivity {
        &self.activity
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct WorkLog(Vec<WorkSpan>);
impl WorkLog {
    pub fn from_spans(spans: Vec<WorkSpan>) -> Result<Self, WorkLogError> {
        for pair in spans.windows(2) {
            if pair[0].stopped.is_none_or(|end| end > pair[1].started) {
                return Err(WorkLogError::Order);
            }
        }
        Ok(Self(spans))
    }
    pub fn spans(&self) -> &[WorkSpan] {
        &self.0
    }
    pub fn active(&self) -> Option<&WorkSpan> {
        self.0.last().filter(|span| span.stopped.is_none())
    }
    pub fn total_seconds(&self, now: WorkTime) -> u64 {
        self.0
            .iter()
            .map(|span| span.stopped.unwrap_or(now).seconds_since(span.started))
            .sum()
    }
    pub(crate) fn start(
        &mut self,
        at: WorkTime,
        activity: &WorkActivity,
    ) -> Result<(), WorkLogError> {
        if let Some(active) = self.active() {
            return if activity.as_str().is_empty() || &active.activity == activity {
                Ok(())
            } else {
                Err(WorkLogError::Active)
            };
        }
        if self
            .0
            .last()
            .is_some_and(|span| span.stopped.is_some_and(|end| end > at))
        {
            return Err(WorkLogError::Order);
        }
        self.0.push(WorkSpan::new(at, None, activity.clone())?);
        Ok(())
    }
    pub(crate) fn stop(&mut self, at: WorkTime) -> Result<(), WorkLogError> {
        if self.active().is_some() {
            let span = self.0.last_mut().expect("active span exists");
            if at < span.started {
                return Err(WorkLogError::Order);
            }
            span.stopped = Some(at);
        }
        Ok(())
    }
    pub(crate) fn correct_stop(&mut self, index: usize, at: WorkTime) -> Result<(), WorkLogError> {
        let span = self.0.get(index).ok_or(WorkLogError::Missing)?;
        if at < span.started || self.0.get(index + 1).is_some_and(|next| at > next.started) {
            return Err(WorkLogError::Order);
        }
        self.0[index].stopped = Some(at);
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkLogError {
    Time,
    Activity,
    Order,
    Active,
    Missing,
}
impl fmt::Display for WorkLogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Time => "time must be UTC in YYYY-MM-DD HH:MM:SS format",
            Self::Activity => "activity must be one line without pipes or surrounding whitespace",
            Self::Order => "work spans must be chronological, non-overlapping, with at most one running span last",
            Self::Active => "pause the running clock before changing its activity",
            Self::Missing => "work span not found (span numbers start at 1)",
        })
    }
}
impl std::error::Error for WorkLogError {}
