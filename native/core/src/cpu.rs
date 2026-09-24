//! This process's CPU time so far, user plus system, all threads: fields 14
//! and 15 of `/proc/self/stat` (Linux and Android). `None` where there is
//! no `/proc` - a reading, not a guess (SPEC §17's "absent is not zero").

use std::time::Duration;

/// Clock ticks per second in `/proc/self/stat`: USER_HZ, 100 on Linux and
/// Android alike.
const TICKS_PER_SECOND: u64 = 100;

/// Fields of `/proc/self/stat` after the command name before `utime`.
const FIELDS_BEFORE_UTIME: usize = 11;

pub(crate) fn process_cpu() -> Option<Duration> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    parse_stat(&stat)
}

fn parse_stat(stat: &str) -> Option<Duration> {
    // Fields from the third on follow the parenthesised command name,
    // which may itself hold spaces and parentheses.
    let mut fields = stat
        .get(stat.rfind(')')? + 2..)?
        .split(' ')
        .skip(FIELDS_BEFORE_UTIME);
    let utime: u64 = fields.next()?.parse().ok()?;
    let stime: u64 = fields.next()?.parse().ok()?;
    Some(Duration::from_millis(
        (utime + stime) * 1000 / TICKS_PER_SECOND,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_utime_plus_stime_past_an_awkward_command_name() {
        let stat = "42 (a) b) S 1 2 3 4 5 6 7 8 9 10 150 25 0 0";
        assert_eq!(parse_stat(stat), Some(Duration::from_millis(1750)));
        assert_eq!(parse_stat("garbage"), None);
    }

    #[test]
    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn this_process_has_a_cpu_reading() {
        assert!(process_cpu().is_some());
    }
}
