//! Windows-side caches, cleaned natively (no shell involved).

use crate::event::Event;
use std::fs;
use std::path::{Path, PathBuf};

pub const CATEGORY: &str = "win-caches";

/// npm and pip caches under %LOCALAPPDATA%. %TEMP% is deliberately out of scope.
pub fn default_dirs(local_app_data: &Path) -> Vec<PathBuf> {
    vec![
        local_app_data.join("npm-cache"),
        local_app_data.join("pip").join("Cache"),
    ]
}

/// Bytes under `p`. Symlinks are counted as themselves and never followed,
/// so a junction into another drive cannot inflate the number.
pub fn dir_size(p: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(p) else {
        return 0;
    };
    if !meta.is_dir() {
        return meta.len();
    }
    fs::read_dir(p)
        .map(|rd| rd.flatten().map(|e| dir_size(&e.path())).sum())
        .unwrap_or(0)
}

fn existing(dirs: &[PathBuf]) -> impl Iterator<Item = &PathBuf> {
    dirs.iter().filter(|d| d.is_dir())
}

pub fn scan(dirs: &[PathBuf], emit: &mut dyn FnMut(Event)) {
    let (mut total, mut count) = (0, 0);
    for d in existing(dirs) {
        let bytes = dir_size(d);
        emit(Event::Item {
            category: CATEGORY.into(),
            path: d.display().to_string(),
            bytes,
        });
        total += bytes;
        count += 1;
    }
    emit(Event::Done {
        category: CATEGORY.into(),
        bytes: total,
        count,
        error: None,
    });
}

pub fn clean(dirs: &[PathBuf], emit: &mut dyn FnMut(Event)) {
    let (mut total, mut count) = (0, 0);
    for d in existing(dirs) {
        let before = dir_size(d);
        // A locked file (npm running) fails remove_dir_all; whatever did go still counts.
        let res = fs::remove_dir_all(d);
        let bytes = before.saturating_sub(dir_size(d));
        if let Err(e) = res {
            emit(Event::log(
                CATEGORY,
                format!("partly cleaned {}: {e}", d.display()),
            ));
        }
        emit(Event::Removed {
            category: CATEGORY.into(),
            path: d.display().to_string(),
            bytes,
        });
        total += bytes;
        count += 1;
    }
    emit(Event::Done {
        category: CATEGORY.into(),
        bytes: total,
        count,
        error: None,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, Vec<PathBuf>) {
        let t = tempfile::tempdir().unwrap();
        let dirs = default_dirs(t.path());
        fs::create_dir_all(dirs[0].join("_cacache/a")).unwrap();
        fs::write(dirs[0].join("_cacache/a/blob"), vec![0u8; 3000]).unwrap();
        fs::write(dirs[0].join("x"), vec![0u8; 100]).unwrap();
        // pip cache missing on purpose
        (t, dirs)
    }

    fn collect(f: impl FnOnce(&mut dyn FnMut(Event))) -> Vec<Event> {
        let mut v = vec![];
        f(&mut |e| v.push(e));
        v
    }

    #[test]
    fn scan_reports_existing_dirs_only_and_deletes_nothing() {
        let (_t, dirs) = fixture();
        let ev = collect(|e| scan(&dirs, e));
        assert_eq!(
            ev,
            vec![
                Event::Item {
                    category: CATEGORY.into(),
                    path: dirs[0].display().to_string(),
                    bytes: 3100
                },
                Event::Done {
                    category: CATEGORY.into(),
                    bytes: 3100,
                    count: 1,
                    error: None
                },
            ]
        );
        assert!(dirs[0].exists());
    }

    #[test]
    fn clean_removes_what_scan_reported() {
        let (_t, dirs) = fixture();
        let ev = collect(|e| clean(&dirs, e));
        assert!(!dirs[0].exists());
        assert_eq!(
            ev.last(),
            Some(&Event::Done {
                category: CATEGORY.into(),
                bytes: 3100,
                count: 1,
                error: None
            })
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_not_followed() {
        let (t, dirs) = fixture();
        let outside = t.path().join("outside");
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("big"), vec![0u8; 50_000]).unwrap();
        std::os::unix::fs::symlink(&outside, dirs[0].join("link")).unwrap();
        assert!(dir_size(&dirs[0]) < 50_000);
        collect(|e| clean(&dirs, e));
        assert!(outside.join("big").exists());
    }
}
