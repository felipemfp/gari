//! Runs one category in scan or clean mode, wherever that category lives.

use crate::category::{Category, Runner};
use crate::event::Event;
use crate::proc::{Tail, stream};
use crate::wincache;
use std::path::{Path, PathBuf};
use std::process::Command;

const GARI_SH: &str = include_str!("../../scripts/gari.sh");
const VHDX_PS1: &str = include_str!("../../scripts/vhdx.ps1");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Scan,
    Clean,
}

impl Mode {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "scan" => Some(Mode::Scan),
            "clean" => Some(Mode::Clean),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Mode::Scan => "scan",
            Mode::Clean => "clean",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Env {
    /// WSL distro that holds the workspace.
    pub distro: String,
    /// %LOCALAPPDATA%\gari: history, the extracted .ps1, compaction logs.
    pub data_dir: PathBuf,
    pub local_app_data: PathBuf,
}

/// `scanned` is what the user saw in the last scan of `cat`. Clean only ever
/// touches paths on it; scan ignores it.
pub fn run(cat: Category, mode: Mode, env: &Env, scanned: &[String], emit: &mut dyn FnMut(Event)) {
    let list = match mode {
        Mode::Scan => None,
        Mode::Clean => match write_list(env, cat, scanned) {
            Ok(p) => Some(p),
            Err(e) => {
                return emit(Event::failed(
                    cat.id(),
                    format!("could not write the clean list: {e}"),
                ));
            }
        },
    };
    match cat.runner() {
        Runner::Wsl => stream(
            wsl_command(env, &step_args(mode, cat, list.as_deref())),
            Some(GARI_SH.as_bytes()),
            cat.id(),
            emit,
        ),
        Runner::Native => {
            let dirs = wincache::default_dirs(&env.local_app_data);
            match mode {
                Mode::Scan => wincache::scan(&dirs, emit),
                Mode::Clean => {
                    let dirs: Vec<_> = dirs
                        .into_iter()
                        .filter(|d| scanned.contains(&d.display().to_string()))
                        .collect();
                    wincache::clean(&dirs, emit)
                }
            }
        }
        Runner::PowerShell => match mode {
            Mode::Scan => powershell(
                env,
                &["-Mode", "scan", "-Distro", &env.distro],
                cat.id(),
                emit,
            ),
            Mode::Clean => match list {
                Some(l) => compact(env, &l, emit),
                None => emit(Event::failed(cat.id(), "no clean list")),
            },
        },
    }
}

/// Disk compaction in two stages, reported as one step (one `done`):
/// 1. unelevated trim: fstrim inside the distros. A sparse disk gives space back
///    right there, no admin, no shutdown. It writes the disks still worth a full
///    compaction to `compact-list.txt`.
/// 2. elevated compact of only those, if any. If the trim stage itself fails,
///    stage 2 falls back to the whole scanned list (the old behaviour).
pub fn compact(env: &Env, scanned_list: &Path, emit: &mut dyn FnMut(Event)) {
    let cat = Category::Vhdx.id();
    let follow_up = env.data_dir.join("compact-list.txt");
    let _ = std::fs::remove_file(&follow_up);
    let mut merge = Merge::default();
    let mut trim_error = None;
    powershell(
        env,
        &[
            "-Mode",
            "trim",
            "-Distro",
            &env.distro,
            "-List",
            &scanned_list.display().to_string(),
            "-Out",
            &follow_up.display().to_string(),
        ],
        cat,
        &mut |e| match e {
            Event::Done {
                error: Some(err), ..
            } => trim_error = Some(err),
            Event::Done { .. } => {}
            other => emit(merge.track(other)),
        },
    );
    let (next, switch): (&Path, Option<&str>) = match &trim_error {
        Some(err) => {
            emit(Event::log(
                cat,
                format!("trim failed ({err}); compacting the scanned non-sparse disks"),
            ));
            // A sparse disk's gap was never measured: not worth un-sparsing blind.
            (scanned_list, Some("NonSparseOnly"))
        }
        None => {
            let todo = std::fs::read_to_string(&follow_up).unwrap_or_default();
            if !lists_any_disk(&todo) {
                return emit(merge.done(cat, None));
            }
            (&follow_up, None)
        }
    };
    elevated(env, "compact", Some(next), switch, cat, &mut |e| match e {
        Event::Done { error, .. } => emit(merge.done(cat, error)),
        other => emit(merge.track(other)),
    });
}

/// Does the trim stage's follow-up list name any disk? A BOM (Windows
/// PowerShell 5.1 writes one with -Encoding utf8) is not a disk: `str::trim`
/// keeps U+FEFF, and a stray one meant a needless UAC prompt.
fn lists_any_disk(text: &str) -> bool {
    text.lines().any(|l| {
        !l.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}')
            .is_empty()
    })
}

/// Folds the removed events of several stages into one total: bytes add up,
/// a disk counts once however many stages shrank it.
#[derive(Default)]
struct Merge {
    bytes: u64,
    paths: std::collections::BTreeSet<String>,
}

impl Merge {
    fn track(&mut self, e: Event) -> Event {
        if let Event::Removed { path, bytes, .. } = &e {
            self.bytes += bytes;
            self.paths.insert(path.clone());
        }
        e
    }

    fn done(&self, cat: &str, error: Option<String>) -> Event {
        Event::Done {
            category: cat.into(),
            bytes: self.bytes,
            count: self.paths.len() as u64,
            error,
        }
    }
}

/// Read-only disk report: the WSL side, then the Windows side. Each ends with
/// its own `done` (categories `report-wsl` and `report-win`).
pub fn report(env: &Env, side: &str, emit: &mut dyn FnMut(Event)) {
    match side {
        "report-wsl" => stream(
            wsl_command(env, &["report"]),
            Some(GARI_SH.as_bytes()),
            side,
            emit,
        ),
        _ => powershell(
            env,
            &["-Mode", "report", "-Distro", &env.distro],
            side,
            emit,
        ),
    }
}

/// One path per line, handed to the clean step. LF endings: bash reads it too.
pub fn write_list(env: &Env, cat: Category, paths: &[String]) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(&env.data_dir)?;
    let p = env.data_dir.join(format!("clean-{}.txt", cat.id()));
    let mut body = paths.join("\n");
    body.push('\n');
    std::fs::write(&p, body)?;
    Ok(p)
}

/// One-time switch so the distro's vhdx gives space back on its own.
pub fn enable_sparse(env: &Env, emit: &mut dyn FnMut(Event)) {
    elevated(env, "sparse", None, None, Category::Vhdx.id(), emit)
}

/// gari.sh arguments for one category step. The list is a Windows path; the
/// script converts it with wslpath.
fn step_args(mode: Mode, cat: Category, list: Option<&Path>) -> Vec<String> {
    let mut a = vec![mode.as_str().to_string(), cat.id().to_string()];
    if let Some(l) = list {
        a.push(list_arg(l));
    }
    a
}

fn wsl_command<S: AsRef<std::ffi::OsStr>>(env: &Env, args: &[S]) -> Command {
    // Off Windows (development inside WSL) the script runs directly.
    let mut c = if cfg!(windows) {
        let mut c = Command::new("wsl.exe");
        // --exec, not --: `--` hands the line to the login shell, which eats the
        // backslashes in the list path (C:\Users\... -> C:Users...) and splits on spaces.
        c.args(["-d", &env.distro, "--exec"]);
        c
    } else {
        Command::new("env")
    };
    c.args(["bash", "-s", "--"]).args(args);
    c
}

/// Forward slashes survive any shell in between; the script hands
/// drive paths (`C:/...`) to wslpath.
fn list_arg(p: &Path) -> String {
    p.display().to_string().replace('\\', "/")
}

/// Default distro name, asked from WSL itself so the registry layout does not matter.
pub fn detect_distro() -> String {
    if !cfg!(windows) {
        return std::env::var("WSL_DISTRO_NAME").unwrap_or_else(|_| "local".into());
    }
    let mut c = Command::new("wsl.exe");
    c.args(["-e", "sh", "-c", "printf %s \"$WSL_DISTRO_NAME\""]);
    crate::proc::hide(&mut c);
    c.output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Ubuntu".into())
}

fn ps1_path(env: &Env) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(&env.data_dir)?;
    let p = env.data_dir.join("vhdx.ps1");
    // UTF-8 BOM so Windows PowerShell 5.1 does not read the file as ANSI.
    std::fs::write(&p, [&b"\xEF\xBB\xBF"[..], VHDX_PS1.as_bytes()].concat())?;
    Ok(p)
}

fn powershell(env: &Env, args: &[&str], category: &str, emit: &mut dyn FnMut(Event)) {
    if !cfg!(windows) {
        return emit(Event::failed(category, "only available on Windows"));
    }
    let ps1 = match ps1_path(env) {
        Ok(p) => p,
        Err(e) => return emit(Event::failed(category, e.to_string())),
    };
    let mut c = Command::new("powershell.exe");
    c.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(&ps1)
        .args(args);
    stream(c, None, category, emit);
}

/// Quotes for a PowerShell single-quoted string.
fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// The command line handed to Start-Process -Verb RunAs. Paths are wrapped in
/// double quotes because Windows PowerShell 5.1 does not quote ArgumentList items.
pub fn elevated_args(
    ps1: &Path,
    mode: &str,
    distro: &str,
    log: &Path,
    list: Option<&Path>,
    switch: Option<&str>,
) -> String {
    let mut inner = format!(
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{}\" -Mode {} -Distro \"{}\" -Log \"{}\"",
        ps1.display(),
        mode,
        distro,
        log.display()
    );
    // vhdx paths resolved by the unelevated scan: an admin account typed into
    // UAC has its own HKCU and LOCALAPPDATA and would find no disks.
    if let Some(l) = list {
        inner.push_str(&format!(" -List \"{}\"", l.display()));
    }
    if let Some(s) = switch {
        inner.push_str(&format!(" -{s}"));
    }
    format!(
        "Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList {}",
        ps_quote(&inner)
    )
}

fn elevated(
    env: &Env,
    mode: &str,
    list: Option<&Path>,
    switch: Option<&str>,
    category: &str,
    emit: &mut dyn FnMut(Event),
) {
    if !cfg!(windows) {
        return emit(Event::failed(category, "only available on Windows"));
    }
    let ps1 = match ps1_path(env) {
        Ok(p) => p,
        Err(e) => return emit(Event::failed(category, e.to_string())),
    };
    let log = env.data_dir.join(format!("{mode}.log"));
    let _ = std::fs::remove_file(&log);
    emit(Event::log(category, "waiting for admin approval (UAC)"));
    let mut c = Command::new("powershell.exe");
    c.args([
        "-NoProfile",
        "-Command",
        &elevated_args(&ps1, mode, &env.distro, &log, list, switch),
    ]);
    crate::proc::hide(&mut c);
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => return emit(Event::failed(category, e.to_string())),
    };
    let mut tail = Tail::default();
    let mut done = false;
    let pump = |tail: &mut Tail, done: &mut bool, emit: &mut dyn FnMut(Event)| {
        for line in tail.read_new(&log).unwrap_or_default() {
            if let Some(ev) = crate::event::parse_line(category, &line) {
                *done |= matches!(ev, Event::Done { .. });
                emit(ev);
            }
        }
    };
    loop {
        pump(&mut tail, &mut done, emit);
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => break,
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(400)),
        }
    }
    pump(&mut tail, &mut done, emit);
    if !done {
        emit(Event::failed(
            category,
            "cancelled at the admin prompt, or the elevated script did not finish",
        ));
    }
}

#[cfg(test)]
mod tests {
    // Regression: a Windows CI checkout with core.autocrlf turned gari.sh into CRLF,
    // and bash in WSL failed on `set -euo pipefail\r`. .gitattributes pins LF.
    // Regression: the list path reached bash as `C:UsersfelipAppData...`.
    #[test]
    fn list_path_is_passed_with_forward_slashes() {
        assert_eq!(
            list_arg(Path::new(
                r"C:\Users\Jane Doe\AppData\Local\gari\clean-caches.txt"
            )),
            "C:/Users/Jane Doe/AppData/Local/gari/clean-caches.txt"
        );
    }

    #[test]
    fn embedded_bash_script_has_lf_endings() {
        assert!(
            !GARI_SH.contains('\r'),
            "scripts/gari.sh must be LF (see .gitattributes)"
        );
    }

    use super::*;

    fn env(root: &Path) -> Env {
        Env {
            distro: "local".into(),
            data_dir: root.join("gari"),
            local_app_data: root.to_path_buf(),
        }
    }

    #[test]
    fn elevated_args_survive_spaces_and_apostrophes() {
        let a = elevated_args(
            Path::new(r"C:\Users\O'Brien Smith\AppData\Local\gari\vhdx.ps1"),
            "compact",
            "Ubuntu",
            Path::new(r"C:\Users\O'Brien Smith\AppData\Local\gari\compact.log"),
            Some(Path::new(
                r"C:\Users\O'Brien Smith\AppData\Local\gari\clean-vhdx.txt",
            )),
            None,
        );
        assert_eq!(
            a,
            r#"Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\O''Brien Smith\AppData\Local\gari\vhdx.ps1" -Mode compact -Distro "Ubuntu" -Log "C:\Users\O''Brien Smith\AppData\Local\gari\compact.log" -List "C:\Users\O''Brien Smith\AppData\Local\gari\clean-vhdx.txt"'"#
        );
    }

    // The trim-failed fallback must reach the elevated script as a switch.
    #[test]
    fn elevated_args_pass_the_non_sparse_switch() {
        let a = elevated_args(
            Path::new(r"C:\g\vhdx.ps1"),
            "compact",
            "Ubuntu",
            Path::new(r"C:\g\compact.log"),
            Some(Path::new(r"C:\g\clean-vhdx.txt")),
            Some("NonSparseOnly"),
        );
        assert!(
            a.ends_with(r#"-List "C:\g\clean-vhdx.txt" -NonSparseOnly'"#),
            "{a}"
        );
    }

    #[test]
    fn native_clean_only_touches_scanned_dirs() {
        let t = tempfile::tempdir().unwrap();
        let e = env(t.path());
        let dirs = wincache::default_dirs(t.path());
        for d in &dirs {
            std::fs::create_dir_all(d).unwrap();
        }
        run(
            Category::WinCaches,
            Mode::Clean,
            &e,
            &[dirs[0].display().to_string()],
            &mut |_| {},
        );
        assert!(!dirs[0].exists());
        assert!(
            dirs[1].exists(),
            "pip cache was not in the scan the user saw"
        );
    }

    #[test]
    fn clean_list_is_one_path_per_line() {
        let t = tempfile::tempdir().unwrap();
        let p = write_list(
            &env(t.path()),
            Category::Caches,
            &["/a b".into(), "/c".into()],
        )
        .unwrap();
        assert_eq!(std::fs::read_to_string(p).unwrap(), "/a b\n/c\n");
    }

    #[test]
    fn mode_parse_rejects_anything_else() {
        assert_eq!(Mode::parse("scan"), Some(Mode::Scan));
        assert_eq!(Mode::parse("clean"), Some(Mode::Clean));
        assert_eq!(Mode::parse("compact"), None);
    }

    #[cfg(not(windows))]
    #[test]
    fn wsl_step_runs_the_embedded_script_end_to_end() {
        let t = tempfile::tempdir().unwrap();
        let ws = t.path().join("ws/app/__pycache__");
        std::fs::create_dir_all(&ws).unwrap();
        std::fs::write(ws.join("m.pyc"), vec![0u8; 4096]).unwrap();
        // The child inherits these; HOME isolates the real caches from the test.
        let e = env(t.path());
        let list = write_list(&e, Category::Caches, &[ws.display().to_string()]).unwrap();
        let mut c = wsl_command(&e, &step_args(Mode::Clean, Category::Caches, Some(&list)));
        c.env("HOME", t.path())
            .env("GARI_ROOT", t.path().join("ws"));
        let mut ev = vec![];
        stream(c, Some(GARI_SH.as_bytes()), "caches", &mut |e| ev.push(e));
        assert!(!ws.exists());
        assert!(
            matches!(ev.last(), Some(Event::Done { count: 1, error: None, bytes, .. }) if *bytes >= 4096)
        );
    }

    fn removed(path: &str, bytes: u64) -> Event {
        Event::Removed {
            category: "vhdx".into(),
            path: path.into(),
            bytes,
        }
    }

    // Regression: an empty follow-up list written by PS 5.1 is BOM + CRLF, and
    // was read as "one disk to compact", so every trim ended in a UAC prompt.
    #[test]
    fn follow_up_list_with_only_bom_and_blank_lines_names_no_disk() {
        assert!(!lists_any_disk("\u{feff}\r\n"));
        assert!(!lists_any_disk(""));
        assert!(!lists_any_disk("\n \r\n"));
        assert!(lists_any_disk("\u{feff}C:\\u\\ext4.vhdx\r\n"));
    }

    // Trim then compact can both shrink one disk: freed bytes add up, the disk
    // counts once, and the run reports a single done for the vhdx step.
    #[test]
    fn merge_sums_bytes_and_counts_each_disk_once() {
        let mut m = Merge::default();
        m.track(removed(r"C:\u.vhdx", 3));
        m.track(removed(r"C:\u.vhdx", 10));
        m.track(removed(r"C:\d.vhdx", 5));
        m.track(Event::log("vhdx", "noise"));
        assert_eq!(
            m.done("vhdx", None),
            Event::Done {
                category: "vhdx".into(),
                bytes: 18,
                count: 2,
                error: None
            }
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn compaction_off_windows_ends_in_exactly_one_failed_done() {
        let t = tempfile::tempdir().unwrap();
        let e = env(t.path());
        let list = write_list(&e, Category::Vhdx, &[r"C:\x.vhdx".into()]).unwrap();
        let mut ev = vec![];
        run(
            Category::Vhdx,
            Mode::Clean,
            &e,
            &[r"C:\x.vhdx".into()],
            &mut |x| ev.push(x),
        );
        let dones: Vec<_> = ev
            .iter()
            .filter(|x| matches!(x, Event::Done { .. }))
            .collect();
        assert_eq!(dones.len(), 1, "{ev:?}");
        assert!(matches!(dones[0], Event::Done { error: Some(_), .. }));
        assert!(list.exists());
    }

    #[cfg(not(windows))]
    #[test]
    fn wsl_report_streams_stats_and_one_done() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(t.path().join(".cache/pip")).unwrap();
        std::fs::write(t.path().join(".cache/pip/blob"), vec![0u8; 8192]).unwrap();
        let e = env(t.path());
        let mut c = wsl_command(&e, &["report"]);
        c.env("HOME", t.path())
            .env("GARI_ROOT", t.path().join("ws"))
            .env("GARI_DOCKER", "false");
        let mut ev = vec![];
        stream(c, Some(GARI_SH.as_bytes()), "report-wsl", &mut |x| {
            ev.push(x)
        });
        assert!(ev.iter().any(|x| matches!(x,
            Event::Stat { section, bytes, .. } if section == "clean-caches" && *bytes >= 8192)));
        let dones = ev
            .iter()
            .filter(|x| matches!(x, Event::Done { .. }))
            .count();
        assert_eq!(dones, 1, "{ev:?}");
        assert!(matches!(ev.last(), Some(Event::Done { error: None, .. })));
    }

    #[cfg(not(windows))]
    #[test]
    fn windows_only_steps_fail_cleanly_elsewhere() {
        let t = tempfile::tempdir().unwrap();
        let mut ev = vec![];
        run(Category::Vhdx, Mode::Scan, &env(t.path()), &[], &mut |e| {
            ev.push(e)
        });
        assert!(matches!(&ev[..], [Event::Done { error: Some(_), .. }]));
    }
}
