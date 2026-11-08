//! What gari can clean, and in which order.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Category {
    Worktrees,
    Caches,
    StaleDeps,
    Docker,
    WinCaches,
    Vhdx,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Runner {
    /// scripts/gari.sh inside the WSL distro.
    Wsl,
    /// Rust, on the Windows side.
    Native,
    /// scripts/vhdx.ps1; compaction runs elevated.
    PowerShell,
}

#[derive(Debug, Clone, Serialize)]
pub struct Info {
    pub id: Category,
    pub label: &'static str,
    pub detail: &'static str,
    /// Cleaning this restarts WSL and Docker Desktop and asks for admin.
    pub disruptive: bool,
}

// Order is the clean order: free space inside the virtual disks first, then
// compact them, so compaction gets to return what the other steps freed.
pub const ALL: [Category; 6] = [
    Category::Worktrees,
    Category::Caches,
    Category::StaleDeps,
    Category::Docker,
    Category::WinCaches,
    Category::Vhdx,
];

impl Category {
    pub fn id(self) -> &'static str {
        match self {
            Category::Worktrees => "worktrees",
            Category::Caches => "caches",
            Category::StaleDeps => "stale-deps",
            Category::Docker => "docker",
            Category::WinCaches => "win-caches",
            Category::Vhdx => "vhdx",
        }
    }

    #[cfg(test)]
    pub fn parse(id: &str) -> Option<Self> {
        ALL.into_iter().find(|c| c.id() == id)
    }

    pub fn runner(self) -> Runner {
        match self {
            Category::WinCaches => Runner::Native,
            Category::Vhdx => Runner::PowerShell,
            _ => Runner::Wsl,
        }
    }

    pub fn info(self) -> Info {
        let (label, detail) = match self {
            Category::Worktrees => (
                "Old worktrees",
                "merged, pushed and clean .claude-worktrees under ~/Workspace",
            ),
            Category::Caches => (
                "Package & Python caches",
                "npm/pnpm/yarn/pip/uv caches, __pycache__, .pytest_cache, .mypy_cache, .ruff_cache",
            ),
            Category::StaleDeps => (
                "Stale node_modules / .venv",
                "projects under ~/Workspace untouched for 30+ days",
            ),
            Category::Docker => (
                "Docker leftovers",
                "unused images, stopped containers, build cache (volumes kept)",
            ),
            Category::WinCaches => (
                "Windows npm & pip caches",
                "%LOCALAPPDATA%\\npm-cache, %LOCALAPPDATA%\\pip\\Cache",
            ),
            Category::Vhdx => (
                "Compact WSL & Docker disks",
                "shrinks the .vhdx files; restarts WSL and Docker Desktop, asks for admin",
            ),
        };
        Info {
            id: self,
            label,
            detail,
            disruptive: self == Category::Vhdx,
        }
    }
}

/// Turns the UI's selection into the run order. Unknown ids and duplicates are
/// dropped; the result always follows `ALL`, so vhdx compaction runs last.
pub fn plan(selected: &[String]) -> Vec<Category> {
    ALL.into_iter()
        .filter(|c| selected.iter().any(|s| s == c.id()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn plan_puts_compaction_last_whatever_the_ui_order() {
        assert_eq!(
            plan(&ids(&["vhdx", "docker", "worktrees", "win-caches"])),
            vec![
                Category::Worktrees,
                Category::Docker,
                Category::WinCaches,
                Category::Vhdx
            ]
        );
    }

    #[test]
    fn plan_drops_unknown_and_duplicate_ids() {
        assert_eq!(
            plan(&ids(&["caches", "rm-rf", "caches"])),
            vec![Category::Caches]
        );
        assert!(plan(&[]).is_empty());
    }

    #[test]
    fn ids_round_trip_and_match_the_script_names() {
        for c in ALL {
            assert_eq!(Category::parse(c.id()), Some(c));
        }
        let script = include_str!("../../scripts/gari.sh");
        for c in ALL.into_iter().filter(|c| c.runner() == Runner::Wsl) {
            assert!(
                script.contains(&format!("{}|", c.id()))
                    || script.contains(&format!("|{})", c.id())),
                "gari.sh does not accept {}",
                c.id()
            );
        }
    }

    #[test]
    fn only_compaction_is_disruptive() {
        let d: Vec<_> = ALL.into_iter().filter(|c| c.info().disruptive).collect();
        assert_eq!(d, vec![Category::Vhdx]);
    }
}
