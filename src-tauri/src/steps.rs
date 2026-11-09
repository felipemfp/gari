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
            wsl_command(env, mode, cat, list.as_deref()),
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
            Mode::Clean => elevated(env, "compact", list.as_deref(), cat.id(), emit),
        },
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
    elevated(env, "sparse", None, Category::Vhdx.id(), emit)
}

fn wsl_command(env: &Env, mode: Mode, cat: Category, list: Option<&Path>) -> Command {
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
    c.args(["bash", "-s", "--", mode.as_str(), cat.id()]);
    // A Windows path; the script converts it with wslpath.
    if let Some(l) = list {
        c.arg(list_arg(l));
    }
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
    format!(
        "Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList {}",
        ps_quote(&inner)
    )
}

fn elevated(
    env: &Env,
    mode: &str,
    list: Option<&Path>,
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
        &elevated_args(&ps1, mode, &env.distro, &log, list),
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
            list_arg(Path::new(r"C:\Users\Jane Doe\AppData\Local\gari\clean-caches.txt")),
            "C:/Users/Jane Doe/AppData/Local/gari/clean-caches.txt"
        );
    }

    #[test]
    fn embedded_bash_script_has_lf_endings() {
        assert!(!GARI_SH.contains('\r'), "scripts/gari.sh must be LF (see .gitattributes)");
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
        );
        assert_eq!(
            a,
            r#"Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\O''Brien Smith\AppData\Local\gari\vhdx.ps1" -Mode compact -Distro "Ubuntu" -Log "C:\Users\O''Brien Smith\AppData\Local\gari\compact.log" -List "C:\Users\O''Brien Smith\AppData\Local\gari\clean-vhdx.txt"'"#
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
        let mut c = wsl_command(&e, Mode::Clean, Category::Caches, Some(&list));
        c.env("HOME", t.path())
            .env("GARI_ROOT", t.path().join("ws"));
        let mut ev = vec![];
        stream(c, Some(GARI_SH.as_bytes()), "caches", &mut |e| ev.push(e));
        assert!(!ws.exists());
        assert!(
            matches!(ev.last(), Some(Event::Done { count: 1, error: None, bytes, .. }) if *bytes >= 4096)
        );
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
