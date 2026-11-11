//! The JSON-lines contract shared by scripts/gari.sh, scripts/vhdx.ps1 and the Rust steps.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "lowercase")]
pub enum Event {
    /// Scan: one candidate.
    Item {
        category: String,
        path: String,
        bytes: u64,
    },
    /// Clean: one candidate is gone.
    Removed {
        category: String,
        path: String,
        bytes: u64,
    },
    Log {
        category: String,
        message: String,
    },
    /// Report: one measurement. `data` is section-specific and passed through to the UI.
    Stat {
        category: String,
        section: String,
        label: String,
        bytes: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        data: Option<serde_json::Value>,
    },
    /// End of a step. `error` is set when the step failed as a whole.
    Done {
        category: String,
        bytes: u64,
        count: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
}

impl Event {
    pub fn log(category: &str, message: impl Into<String>) -> Self {
        Event::Log {
            category: category.into(),
            message: message.into(),
        }
    }

    pub fn failed(category: &str, error: impl Into<String>) -> Self {
        Event::Done {
            category: category.into(),
            bytes: 0,
            count: 0,
            error: Some(error.into()),
        }
    }
}

/// Parses one output line. Anything that is not a contract event (tool noise,
/// a PowerShell warning, a BOM) becomes a log line instead of being dropped.
pub fn parse_line(category: &str, line: &str) -> Option<Event> {
    let line = line.trim_start_matches('\u{feff}').trim();
    if line.is_empty() {
        return None;
    }
    Some(serde_json::from_str(line).unwrap_or_else(|_| Event::log(category, line)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_event_kind() {
        assert_eq!(
            parse_line(
                "caches",
                r#"{"event":"item","category":"caches","path":"/a b","bytes":12}"#
            ),
            Some(Event::Item {
                category: "caches".into(),
                path: "/a b".into(),
                bytes: 12
            })
        );
        assert_eq!(
            parse_line(
                "x",
                r#"{"event":"removed","category":"docker","path":"p","bytes":0}"#
            ),
            Some(Event::Removed {
                category: "docker".into(),
                path: "p".into(),
                bytes: 0
            })
        );
        assert_eq!(
            parse_line(
                "x",
                r#"{"event":"done","category":"vhdx","bytes":5,"count":2}"#
            ),
            Some(Event::Done {
                category: "vhdx".into(),
                bytes: 5,
                count: 2,
                error: None
            })
        );
    }

    #[test]
    fn extra_fields_from_powershell_are_ignored() {
        let e = parse_line(
            "vhdx",
            r#"{"event":"item","category":"vhdx","path":"C:\\x.vhdx","bytes":1,"size":9,"used":null}"#,
        );
        assert_eq!(
            e,
            Some(Event::Item {
                category: "vhdx".into(),
                path: "C:\\x.vhdx".into(),
                bytes: 1
            })
        );
    }

    #[test]
    fn noise_becomes_a_log_line_and_blank_lines_vanish() {
        assert_eq!(
            parse_line("docker", "WARNING: thing"),
            Some(Event::log("docker", "WARNING: thing"))
        );
        assert_eq!(parse_line("docker", "  \r"), None);
        assert_eq!(
            parse_line(
                "vhdx",
                "\u{feff}{\"event\":\"log\",\"category\":\"vhdx\",\"message\":\"hi\"}"
            ),
            Some(Event::log("vhdx", "hi"))
        );
    }

    #[test]
    fn negative_bytes_is_noise_not_a_panic() {
        assert_eq!(
            parse_line(
                "c",
                r#"{"event":"item","category":"c","path":"p","bytes":-1}"#
            ),
            Some(Event::log(
                "c",
                r#"{"event":"item","category":"c","path":"p","bytes":-1}"#
            ))
        );
    }

    #[test]
    fn stat_keeps_its_data_and_null_data_is_none() {
        let e = parse_line(
            "report-win",
            r#"{"event":"stat","category":"report-win","section":"vhdx","label":"Ubuntu","bytes":5,"data":{"sparse":true,"used":null}}"#,
        );
        assert_eq!(
            e,
            Some(Event::Stat {
                category: "report-win".into(),
                section: "vhdx".into(),
                label: "Ubuntu".into(),
                bytes: 5,
                data: Some(serde_json::json!({"sparse": true, "used": null})),
            })
        );
        // gari.sh prints "data":null when a stat has nothing extra.
        let e = parse_line(
            "report-wsl",
            r#"{"event":"stat","category":"report-wsl","section":"wsl-home","label":"/h/.cache","bytes":1,"data":null}"#,
        );
        assert!(matches!(e, Some(Event::Stat { data: None, .. })));
    }

    #[test]
    fn serializes_back_to_the_same_shape() {
        let e = Event::failed("docker", "boom");
        assert_eq!(
            serde_json::to_string(&e).unwrap(),
            r#"{"event":"done","category":"docker","bytes":0,"count":0,"error":"boom"}"#
        );
    }
}
