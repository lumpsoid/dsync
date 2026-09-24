//! What one transfer took: bytes and files moved, wall time, and the
//! process CPU spent over the same span.

use std::fmt;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct TransferMetrics {
    pub bytes: u64,
    pub files: u64,
    pub wall: Duration,
    /// None where the platform has no /proc/self/stat.
    pub cpu: Option<Duration>,
}

impl TransferMetrics {
    pub fn mib(&self) -> f64 {
        self.bytes as f64 / (1u64 << 20) as f64
    }

    fn seconds(&self) -> f64 {
        self.wall.as_secs_f64().max(1e-6)
    }

    pub fn mib_per_second(&self) -> f64 {
        self.mib() / self.seconds()
    }

    pub fn files_per_second(&self) -> f64 {
        self.files as f64 / self.seconds()
    }

    pub fn cpu_seconds(&self) -> Option<f64> {
        self.cpu.map(|c| c.as_secs_f64())
    }

    /// None with no CPU reading or no bytes.
    pub fn cpu_ms_per_mib(&self) -> Option<f64> {
        let cpu = self.cpu?;
        (self.bytes > 0).then(|| cpu.as_secs_f64() * 1000.0 / self.mib())
    }
}

impl fmt::Display for TransferMetrics {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} files  {:.1} MiB in {:.2} s  {:.1} MiB/s  {:.0} files/s",
            self.files,
            self.mib(),
            self.seconds(),
            self.mib_per_second(),
            self.files_per_second(),
        )?;
        match (self.cpu_seconds(), self.cpu_ms_per_mib()) {
            (Some(s), Some(per_mib)) => write!(f, "  cpu {s:.2} s  {per_mib:.1} ms/MiB"),
            (Some(s), None) => write!(f, "  cpu {s:.2} s"),
            _ => write!(f, "  cpu -"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rates_are_per_wall_second_and_cpu_per_mib() {
        let metrics = TransferMetrics {
            bytes: 64 << 20,
            files: 32,
            wall: Duration::from_secs(2),
            cpu: Some(Duration::from_millis(640)),
        };
        assert_eq!(metrics.mib_per_second(), 32.0);
        assert_eq!(metrics.files_per_second(), 16.0);
        assert_eq!(metrics.cpu_ms_per_mib(), Some(10.0));
    }
}
