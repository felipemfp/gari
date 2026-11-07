//! Run history: one JSON object per clean run in %LOCALAPPDATA%\gari\runs.jsonl.

use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StepResult {
    pub category: String,
    pub bytes: u64,
    pub count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Run {
    /// Unix seconds.
    pub ts: u64,
    pub steps: Vec<StepResult>,
}

impl Run {
    pub fn freed(&self) -> u64 {
        self.steps.iter().map(|s| s.bytes).sum()
    }
}

pub fn append(path: &Path, run: &Run) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(f, "{}", serde_json::to_string(run)?)
}

/// Last readable run. A torn or hand-edited line is skipped, never fatal.
pub fn last(path: &Path) -> Option<Run> {
    let text = fs::read_to_string(path).ok()?;
    text.lines()
        .rev()
        .find_map(|l| serde_json::from_str(l).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(ts: u64, bytes: &[u64]) -> Run {
        Run {
            ts,
            steps: bytes
                .iter()
                .map(|b| StepResult {
                    category: "caches".into(),
                    bytes: *b,
                    count: 1,
                    error: None,
                })
                .collect(),
        }
    }

    #[test]
    fn append_then_last_returns_newest() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("nested/runs.jsonl");
        assert_eq!(last(&p), None);
        append(&p, &run(1, &[10])).unwrap();
        append(&p, &run(2, &[5, 7])).unwrap();
        let r = last(&p).unwrap();
        assert_eq!(r.ts, 2);
        assert_eq!(r.freed(), 12);
        assert_eq!(fs::read_to_string(&p).unwrap().lines().count(), 2);
    }

    #[test]
    fn torn_last_line_falls_back_to_previous_run() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("runs.jsonl");
        append(&p, &run(1, &[3])).unwrap();
        fs::write(
            &p,
            format!("{}{{\"ts\":2,\"ste", fs::read_to_string(&p).unwrap()),
        )
        .unwrap();
        assert_eq!(last(&p).unwrap().ts, 1);
    }
}
