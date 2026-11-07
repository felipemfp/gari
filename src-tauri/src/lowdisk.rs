//! Tray warning when the system drive runs low.

pub const THRESHOLD: u64 = 20 * 1_000_000_000;

/// Fires once when free space drops below the threshold, and re-arms only after
/// it climbs back above, so a full disk does not nag every check.
pub struct Alarm {
    threshold: u64,
    armed: bool,
}

impl Alarm {
    pub fn new(threshold: u64) -> Self {
        Alarm {
            threshold,
            armed: true,
        }
    }

    pub fn check(&mut self, free: u64) -> bool {
        if free >= self.threshold {
            self.armed = true;
            return false;
        }
        std::mem::replace(&mut self.armed, false)
    }
}

/// Free bytes on the drive holding the system (C:\ on Windows, / elsewhere).
pub fn system_free() -> Option<u64> {
    let mount = if cfg!(windows) { "C:\\" } else { "/" };
    sysinfo::Disks::new_with_refreshed_list()
        .ok()?
        .iter()
        .find(|d| d.mount_point().as_os_str() == mount)
        .map(|d| d.available_space())
}

pub fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1000.0 && i < UNITS.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 {
        format!("{bytes} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fires_once_per_crossing() {
        let mut a = Alarm::new(100);
        assert!(!a.check(500));
        assert!(a.check(50));
        assert!(!a.check(40));
        assert!(!a.check(100));
        assert!(a.check(99));
    }

    #[test]
    fn starts_armed_when_already_low() {
        assert!(Alarm::new(100).check(0));
    }

    #[test]
    fn human_uses_si_units_like_docker_and_the_ui() {
        assert_eq!(human(0), "0 B");
        assert_eq!(human(999), "999 B");
        assert_eq!(human(1_500_000_000), "1.5 GB");
        assert_eq!(human(20 * 1_000_000_000_000), "20.0 TB");
    }

    #[test]
    fn system_free_finds_the_root_drive() {
        assert!(system_free().is_some());
    }
}
