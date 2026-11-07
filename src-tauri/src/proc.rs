//! Running the step processes and streaming their JSON lines.

use crate::event::{Event, parse_line};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::process::{Command, Stdio};

/// Spawns `cmd`, optionally feeds `stdin`, and emits one event per stdout line.
/// Guarantees exactly one Done event: if the process dies without one
/// (wsl.exe missing, script crashed), a failed Done is synthesized.
pub fn stream(mut cmd: Command, stdin: Option<&[u8]>, category: &str, emit: &mut dyn FnMut(Event)) {
    hide(&mut cmd);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    cmd.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return emit(Event::failed(
                category,
                format!("could not start {:?}: {e}", cmd.get_program()),
            ));
        }
    };
    if let (Some(data), Some(mut w)) = (stdin, child.stdin.take()) {
        let data = data.to_vec();
        // Written from a thread so a large script cannot deadlock against a full stdout pipe.
        std::thread::spawn(move || {
            let _ = w.write_all(&data);
        });
    }
    let mut stderr = child.stderr.take().unwrap();
    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stderr.read_to_string(&mut s);
        s
    });
    let mut done = false;
    for line in BufReader::new(child.stdout.take().unwrap()).lines() {
        let Ok(line) = line else { break };
        if let Some(ev) = parse_line(category, &line) {
            done |= matches!(ev, Event::Done { .. });
            emit(ev);
        }
    }
    let status = child.wait();
    let err = err_thread.join().unwrap_or_default();
    for l in err.lines().filter(|l| !l.trim().is_empty()) {
        emit(Event::log(category, l.trim()));
    }
    if !done {
        let why = match status {
            Ok(s) => format!("exited with {s} before finishing"),
            Err(e) => e.to_string(),
        };
        emit(Event::failed(category, why));
    }
}

/// No console window flashing up for every wsl.exe / powershell.exe call.
#[cfg(windows)]
pub fn hide(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
pub fn hide(_: &mut Command) {}

/// Follows a file another process appends to (the elevated vhdx.ps1 log).
/// Returns only complete lines; a half-written line waits for the next read.
#[derive(Default)]
pub struct Tail {
    offset: u64,
    partial: String,
}

impl Tail {
    pub fn read_new(&mut self, path: &Path) -> io::Result<Vec<String>> {
        let mut f = match File::open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(e),
        };
        f.seek(SeekFrom::Start(self.offset))?;
        let mut buf = Vec::new();
        self.offset += f.read_to_end(&mut buf)? as u64;
        self.partial.push_str(&String::from_utf8_lossy(&buf));
        let mut lines: Vec<String> = self
            .partial
            .split('\n')
            .map(|s| s.trim_end_matches('\r').to_string())
            .collect();
        self.partial = lines.pop().unwrap_or_default();
        Ok(lines.into_iter().filter(|l| !l.is_empty()).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str) -> Command {
        let mut c = Command::new("sh");
        c.arg("-c").arg(script);
        c
    }

    fn run(cmd: Command, stdin: Option<&[u8]>) -> Vec<Event> {
        let mut v = vec![];
        stream(cmd, stdin, "caches", &mut |e| v.push(e));
        v
    }

    #[test]
    fn streams_events_and_stderr_as_logs() {
        let ev = run(
            sh(
                r#"echo '{"event":"item","category":"caches","path":"p","bytes":1}'; echo oops >&2; echo '{"event":"done","category":"caches","bytes":1,"count":1}'"#,
            ),
            None,
        );
        assert_eq!(ev.len(), 3);
        assert!(matches!(ev[0], Event::Item { bytes: 1, .. }));
        assert!(matches!(ev[1], Event::Done { error: None, .. }));
        assert_eq!(ev[2], Event::log("caches", "oops"));
    }

    #[test]
    fn feeds_stdin_like_bash_dash_s() {
        let script = br#"echo '{"event":"done","category":"caches","bytes":7,"count":0}'"#;
        let mut c = Command::new("sh");
        c.arg("-s");
        let ev = run(c, Some(script));
        assert_eq!(
            ev,
            vec![Event::Done {
                category: "caches".into(),
                bytes: 7,
                count: 0,
                error: None
            }]
        );
    }

    #[test]
    fn crash_without_done_synthesizes_a_failed_done() {
        let ev = run(sh("exit 3"), None);
        assert!(matches!(&ev[..], [Event::Done { error: Some(e), .. }] if e.contains("3")));
    }

    #[test]
    fn missing_program_is_a_failed_done_not_a_panic() {
        let ev = run(Command::new("/definitely/not/here"), None);
        assert!(matches!(&ev[..], [Event::Done { error: Some(_), .. }]));
    }

    #[test]
    fn tail_returns_only_complete_new_lines() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("log");
        let mut t = Tail::default();
        assert!(t.read_new(&p).unwrap().is_empty());
        std::fs::write(&p, "a\r\nb").unwrap();
        assert_eq!(t.read_new(&p).unwrap(), vec!["a"]);
        let mut f = std::fs::OpenOptions::new().append(true).open(&p).unwrap();
        write!(f, "c\nd\n").unwrap();
        assert_eq!(t.read_new(&p).unwrap(), vec!["bc", "d"]);
        assert!(t.read_new(&p).unwrap().is_empty());
    }
}
