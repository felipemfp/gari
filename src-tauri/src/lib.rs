mod category;
mod event;
mod history;
mod lowdisk;
mod proc;
mod steps;
mod wincache;

use category::{ALL, Info, plan};
use event::Event;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use steps::{Env, Mode};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, WindowEvent};
use tauri_plugin_notification::NotificationExt;

struct State {
    busy: Arc<AtomicBool>,
    env: Env,
}

/// Sent before each step so the UI can show "step i of n".
#[derive(Clone, Serialize)]
struct Step {
    mode: &'static str,
    index: usize,
    total: usize,
    category: &'static str,
}

#[derive(Clone, Serialize)]
struct Finished {
    mode: &'static str,
    freed: u64,
    errors: Vec<String>,
}

fn history_path(env: &Env) -> PathBuf {
    env.data_dir.join("runs.jsonl")
}

#[tauri::command]
fn categories() -> Vec<Info> {
    ALL.into_iter().map(|c| c.info()).collect()
}

#[tauri::command]
fn last_run(state: tauri::State<State>) -> Option<history::Run> {
    history::last(&history_path(&state.env))
}

#[tauri::command]
fn distro(state: tauri::State<State>) -> String {
    state.env.distro.clone()
}

/// Claims the single run slot; the guard releases it when the run thread ends.
fn claim(busy: &Arc<AtomicBool>) -> Result<BusyGuard, String> {
    if busy.swap(true, Ordering::SeqCst) {
        return Err("a run is already in progress".into());
    }
    Ok(BusyGuard(busy.clone()))
}

struct BusyGuard(Arc<AtomicBool>);
impl Drop for BusyGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[tauri::command]
fn start(
    app: AppHandle,
    state: tauri::State<State>,
    mode: String,
    categories: Vec<String>,
    // Clean only: the paths each category's scan showed the user.
    scanned: Option<HashMap<String, Vec<String>>>,
) -> Result<(), String> {
    let scanned = scanned.unwrap_or_default();
    let mode = Mode::parse(&mode).ok_or("mode must be scan or clean")?;
    let cats = plan(&categories);
    if cats.is_empty() {
        return Err("nothing selected".into());
    }
    let guard = claim(&state.busy)?;
    let env = state.env.clone();
    std::thread::spawn(move || {
        let _guard = guard;
        let mode_s = if mode == Mode::Scan { "scan" } else { "clean" };
        let mut results = vec![];
        for (i, c) in cats.iter().enumerate() {
            let _ = app.emit(
                "gari://step",
                Step {
                    mode: mode_s,
                    index: i,
                    total: cats.len(),
                    category: c.id(),
                },
            );
            let list = scanned.get(c.id()).map(Vec::as_slice).unwrap_or(&[]);
            steps::run(*c, mode, &env, list, &mut |e| {
                if let Event::Done {
                    category,
                    bytes,
                    count,
                    error,
                } = &e
                {
                    results.push(history::StepResult {
                        category: category.clone(),
                        bytes: *bytes,
                        count: *count,
                        error: error.clone(),
                    });
                }
                let _ = app.emit("gari://event", e);
            });
        }
        let run = history::Run {
            ts: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_secs()),
            steps: results,
        };
        let errors: Vec<String> = run
            .steps
            .iter()
            .filter_map(|s| s.error.as_ref().map(|e| format!("{}: {e}", s.category)))
            .collect();
        if mode == Mode::Clean {
            if let Err(e) = history::append(&history_path(&env), &run) {
                let _ = app.emit(
                    "gari://event",
                    Event::log("history", format!("could not save run history: {e}")),
                );
            }
            let body = if errors.is_empty() {
                format!("Freed {}", lowdisk::human(run.freed()))
            } else {
                format!(
                    "Freed {}, {} step(s) failed",
                    lowdisk::human(run.freed()),
                    errors.len()
                )
            };
            let _ = app.notification().builder().title("gari").body(body).show();
        }
        let _ = app.emit(
            "gari://finished",
            Finished {
                mode: mode_s,
                freed: run.freed(),
                errors,
            },
        );
    });
    Ok(())
}

/// Read-only disk report. Streams `stat` events; the UI builds the report and
/// its recommendations from them.
#[tauri::command]
fn report(app: AppHandle, state: tauri::State<State>) -> Result<(), String> {
    let guard = claim(&state.busy)?;
    let env = state.env.clone();
    std::thread::spawn(move || {
        let _guard = guard;
        let sides = ["report-wsl", "report-win"];
        let mut errors = vec![];
        for (i, side) in sides.iter().enumerate() {
            let _ = app.emit(
                "gari://step",
                Step {
                    mode: "report",
                    index: i,
                    total: sides.len(),
                    category: side,
                },
            );
            steps::report(&env, side, &mut |e| {
                if let Event::Done {
                    error: Some(err), ..
                } = &e
                {
                    errors.push(format!("{side}: {err}"));
                }
                let _ = app.emit("gari://event", e);
            });
        }
        let _ = app.emit(
            "gari://finished",
            Finished {
                mode: "report",
                freed: 0,
                errors,
            },
        );
    });
    Ok(())
}

#[tauri::command]
fn enable_sparse(app: AppHandle, state: tauri::State<State>) -> Result<(), String> {
    let guard = claim(&state.busy)?;
    let env = state.env.clone();
    std::thread::spawn(move || {
        let _guard = guard;
        let _ = app.emit(
            "gari://step",
            Step {
                mode: "sparse",
                index: 0,
                total: 1,
                category: "vhdx",
            },
        );
        let mut errors = vec![];
        steps::enable_sparse(&env, &mut |e| {
            if let Event::Done {
                error: Some(err), ..
            } = &e
            {
                errors.push(err.clone());
            }
            let _ = app.emit("gari://event", e);
        });
        let _ = app.emit(
            "gari://finished",
            Finished {
                mode: "sparse",
                freed: 0,
                errors,
            },
        );
    });
    Ok(())
}

fn show(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn watch_disk(app: AppHandle) {
    std::thread::spawn(move || {
        let mut alarm = lowdisk::Alarm::new(lowdisk::THRESHOLD);
        loop {
            if let Some(free) = lowdisk::system_free()
                && alarm.check(free)
            {
                let _ = app
                    .notification()
                    .builder()
                    .title("gari: disk almost full")
                    .body(format!(
                        "Only {} free. Open gari to clean up.",
                        lowdisk::human(free)
                    ))
                    .show();
            }
            std::thread::sleep(Duration::from_secs(30 * 60));
        }
    });
}

pub fn run() {
    let local = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let env = Env {
        distro: steps::detect_distro(),
        data_dir: local.join("gari"),
        local_app_data: local,
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(State {
            busy: Arc::new(AtomicBool::new(false)),
            env,
        })
        .invoke_handler(tauri::generate_handler![
            categories,
            last_run,
            distro,
            start,
            report,
            enable_sparse
        ])
        .setup(|app| {
            let open = MenuItem::with_id(app, "open", "Open gari", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            TrayIconBuilder::new()
                .icon(
                    app.default_window_icon()
                        .cloned()
                        .ok_or("missing app icon")?,
                )
                .tooltip("gari")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "open" => show(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = e
                    {
                        show(tray.app_handle());
                    }
                })
                .build(app)?;
            watch_disk(app.handle().clone());
            Ok(())
        })
        .on_window_event(|w, e| {
            // Closing the window keeps gari in the tray; Quit is in the tray menu.
            if let WindowEvent::CloseRequested { api, .. } = e {
                api.prevent_close();
                let _ = w.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running gari");
}
