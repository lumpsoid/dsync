//! What a scan probe measured, and its rendering (task 1a341e): one tree
//! walked several times, each walk one named step more than the one below,
//! so the difference between two rungs is the cost of that step alone.

use std::fmt;
use std::path::PathBuf;
use std::time::Duration;

use crate::metric_format::{format_bytes, format_count, format_duration};

/// One rung, in ascending order of what it does per path.
///
/// `List` and `Stat` are the platform's floor, the syscalls a walk of the
/// tree cannot avoid on this device; `Rules` and above are this project's
/// code.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum ScanProbeLayer {
    /// Each directory listed without following links, children recursed
    /// into as the listing typed them, and the walk's sort (pure CPU, kept
    /// in the floor so every other step is one named addition).
    List,
    /// `List` plus a stat per file on the scanner's pool: the size and
    /// mtime the fast path compares and the mode §7.4 carries.
    Stat,
    /// Adds SPEC §5.1's per-path decisions: the relative path, the ignore
    /// match and the scratch-file check. No archive, no hashing.
    Rules,
    /// A real scan against an archive that already matches the tree:
    /// every file takes the fast path and nothing is hashed.
    ScanWarmArchive,
    /// A real scan against an empty archive, a first sync's shape: every
    /// file is hashed.
    ScanEmptyArchive,
}

impl ScanProbeLayer {
    /// Every rung, in ladder order.
    pub const ALL: [ScanProbeLayer; 5] = [
        ScanProbeLayer::List,
        ScanProbeLayer::Stat,
        ScanProbeLayer::Rules,
        ScanProbeLayer::ScanWarmArchive,
        ScanProbeLayer::ScanEmptyArchive,
    ];

    /// The rung's name, as both the text report and the head show it.
    pub fn label(self) -> &'static str {
        match self {
            ScanProbeLayer::List => "list",
            ScanProbeLayer::Stat => "list+stat",
            ScanProbeLayer::Rules => "+§5.1 rules",
            ScanProbeLayer::ScanWarmArchive => "scan (warm archive)",
            ScanProbeLayer::ScanEmptyArchive => "scan (empty archive)",
        }
    }

    /// Whether the rung stats each file. Said per rung rather than read
    /// off declaration order, so a rung added later cannot quietly change
    /// another's walk.
    pub fn stats_files(self) -> bool {
        self != ScanProbeLayer::List
    }

    /// Whether the rung builds relative paths and applies SPEC §5.1.
    pub fn applies_rules(self) -> bool {
        matches!(
            self,
            ScanProbeLayer::Rules
                | ScanProbeLayer::ScanWarmArchive
                | ScanProbeLayer::ScanEmptyArchive
        )
    }
}

/// What one rung cost on one pass.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ScanProbeLayerResult {
    pub layer: ScanProbeLayer,
    pub elapsed: Duration,
    /// Regular files the rung visited, counted per rung: a rung that
    /// disagrees did not walk the same tree.
    pub files: u64,
    /// Directories traversed, or `None` for a rung that runs the scanner,
    /// whose result does not report directories.
    pub directories: Option<u64>,
    /// Total size of the files stat'd; 0 for a rung that never stats.
    pub bytes: u64,
}

impl ScanProbeLayerResult {
    /// Microseconds per file visited: evidence only across two roots of
    /// different sizes, arithmetic on one.
    pub fn micros_per_file(&self) -> f64 {
        if self.files == 0 {
            0.0
        } else {
            self.elapsed.as_micros() as f64 / self.files as f64
        }
    }
}

/// One climb of the ladder. Pass 0 reads whatever cache state the device
/// was in; later passes are warm.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ScanProbePass {
    pub index: usize,
    pub layers: Vec<ScanProbeLayerResult>,
}

impl ScanProbePass {
    pub fn get(&self, layer: ScanProbeLayer) -> Option<&ScanProbeLayerResult> {
        self.layers.iter().find(|result| result.layer == layer)
    }
}

/// The same ladder climbed over one root, back to back.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ScanProbeReport {
    /// The root as the scanner resolves it (links followed).
    pub root: PathBuf,
    pub passes: Vec<ScanProbePass>,
}

/// One named step and the two rungs whose difference is its cost, printed
/// beside the figure so a subtracted number shows its inputs (SPEC §17).
struct Step {
    name: &'static str,
    above: ScanProbeLayer,
    below: Option<ScanProbeLayer>,
    derivation: &'static str,
}

const STEPS: [Step; 5] = [
    Step {
        name: "list + sort",
        above: ScanProbeLayer::List,
        below: None,
        derivation: "(list)",
    },
    Step {
        name: "stat per file",
        above: ScanProbeLayer::Stat,
        below: Some(ScanProbeLayer::List),
        derivation: "(list+stat − list)",
    },
    Step {
        name: "§5.1 rules + path building",
        above: ScanProbeLayer::Rules,
        below: Some(ScanProbeLayer::Stat),
        derivation: "(+§5.1 rules − list+stat)",
    },
    Step {
        name: "archive + §16 + ScanResult",
        above: ScanProbeLayer::ScanWarmArchive,
        below: Some(ScanProbeLayer::Rules),
        derivation: "(scan warm − +§5.1 rules)",
    },
    Step {
        name: "SHA-256 hashing",
        above: ScanProbeLayer::ScanEmptyArchive,
        below: Some(ScanProbeLayer::ScanWarmArchive),
        derivation: "(scan empty − scan warm)",
    },
];

/// The report as plain text, for pasting into a message.
impl fmt::Display for ScanProbeReport {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(out, "scan probe: {}", self.root.display())?;
        let Some(first) = self.passes.first() else {
            writeln!(out, "  no passes run")?;
            return Ok(());
        };
        if let Some(floor) = first.get(ScanProbeLayer::Stat) {
            writeln!(
                out,
                "  {} files, {}, {} directories",
                format_count(floor.files),
                format_bytes(floor.bytes),
                format_count(floor.directories.unwrap_or(0)),
            )?;
        }

        for pass in &self.passes {
            writeln!(out)?;
            let warm = if pass.index == 0 { "" } else { " (warm)" };
            writeln!(out, "pass {}{warm}", pass.index)?;
            writeln!(
                out,
                "  {:<24}{:>10}{:>9}{:>10}",
                "layer", "elapsed", "files", "µs/file"
            )?;
            for layer in ScanProbeLayer::ALL {
                let Some(result) = pass.get(layer) else {
                    continue;
                };
                writeln!(
                    out,
                    "  {:<24}{:>10}{:>9}{:>10.0}",
                    layer.label(),
                    format_duration(result.elapsed),
                    format_count(result.files),
                    result.micros_per_file(),
                )?;
            }

            writeln!(out)?;
            writeln!(out, "  attribution")?;
            let mut any_negative = false;
            for step in &STEPS {
                let Some(above) = pass.get(step.above) else {
                    continue;
                };
                let below = match step.below {
                    None => Duration::ZERO,
                    Some(layer) => match pass.get(layer) {
                        Some(result) => result.elapsed,
                        None => continue,
                    },
                };
                any_negative |= above.elapsed < below;
                writeln!(
                    out,
                    "    {:<40}{:>10}   {}",
                    step.name,
                    format_delta(above.elapsed, below),
                    step.derivation,
                )?;
            }
            if any_negative {
                // A rung cannot cost less than the rung it contains: a
                // negative step is this pass's noise floor made visible.
                writeln!(
                    out,
                    "    (a negative step is noise: that rung came out cheaper than the one it contains)"
                )?;
            }

            if let (Some(floor), Some(full)) = (
                pass.get(ScanProbeLayer::Stat),
                pass.get(ScanProbeLayer::ScanEmptyArchive),
            ) {
                writeln!(out)?;
                writeln!(
                    out,
                    "  platform floor (list+stat)      {:>10}   {} of the full scan",
                    format_duration(floor.elapsed),
                    percent(floor.elapsed, full.elapsed),
                )?;
                writeln!(
                    out,
                    "  this code, on top of the floor  {:>10}   {} of the full scan",
                    format_delta(full.elapsed, floor.elapsed),
                    percent(full.elapsed.saturating_sub(floor.elapsed), full.elapsed),
                )?;
            }
        }
        Ok(())
    }
}

/// `above - below`, signed: a duration has no sign of its own.
fn format_delta(above: Duration, below: Duration) -> String {
    if above >= below {
        format_duration(above - below)
    } else {
        format!("-{}", format_duration(below - above))
    }
}

fn percent(part: Duration, whole: Duration) -> String {
    if whole.is_zero() {
        "—".to_owned()
    } else {
        format!("{:.0}%", 100.0 * part.as_secs_f64() / whole.as_secs_f64())
    }
}

#[cfg(test)]
mod tests {
    //! The rendering cases of `scan_probe_test.dart`; the rungs themselves
    //! are measured by the core's probe tests.

    use super::*;

    fn result(layer: ScanProbeLayer, millis: u64) -> ScanProbeLayerResult {
        ScanProbeLayerResult {
            layer,
            elapsed: Duration::from_millis(millis),
            files: 3,
            directories: (!matches!(
                layer,
                ScanProbeLayer::ScanWarmArchive | ScanProbeLayer::ScanEmptyArchive
            ))
            .then_some(1),
            bytes: if layer.stats_files() { 6 } else { 0 },
        }
    }

    fn report(millis: [u64; 5]) -> ScanProbeReport {
        ScanProbeReport {
            root: PathBuf::from("/tmp/tree"),
            passes: (0..2)
                .map(|index| ScanProbePass {
                    index,
                    layers: ScanProbeLayer::ALL
                        .iter()
                        .zip(millis)
                        .map(|(layer, ms)| result(*layer, ms))
                        .collect(),
                })
                .collect(),
        }
    }

    #[test]
    fn every_rung_and_its_derivation_is_shown() {
        let text = report([10, 20, 25, 30, 90]).to_string();
        assert!(text.starts_with("scan probe: /tmp/tree\n"), "{text}");
        assert!(text.contains("  3 files, 6 B, 1 directories\n"), "{text}");
        for layer in ScanProbeLayer::ALL {
            assert!(text.contains(layer.label()), "{text}");
        }
        assert!(text.contains("(list+stat − list)"), "{text}");
        assert!(text.contains("SHA-256 hashing"), "{text}");
        assert!(text.contains("(scan empty − scan warm)"), "{text}");
        assert!(text.contains("platform floor (list+stat)"), "{text}");
        assert!(text.contains("pass 1 (warm)"), "{text}");
        assert!(
            text.contains("60.0 ms   (scan empty − scan warm)"),
            "{text}"
        );
        assert!(text.contains("22%"), "floor 20 of 90: {text}");
        assert!(!text.contains("noise"), "{text}");
    }

    #[test]
    fn a_negative_step_is_signed_and_called_noise() {
        let text = report([10, 20, 15, 30, 90]).to_string();
        assert!(text.contains("-5.0 ms"), "{text}");
        assert!(text.contains("a negative step is noise"), "{text}");
    }

    #[test]
    fn an_empty_report_renders() {
        let report = ScanProbeReport {
            root: PathBuf::from("/tmp/none"),
            passes: vec![],
        };
        assert!(report.to_string().contains("no passes run"));
    }

    #[test]
    fn rung_behaviour_is_said_per_rung() {
        assert!(!ScanProbeLayer::List.stats_files());
        assert!(ScanProbeLayer::Stat.stats_files());
        assert!(!ScanProbeLayer::Stat.applies_rules());
        assert!(ScanProbeLayer::Rules.applies_rules());
        assert!(ScanProbeLayer::ScanEmptyArchive.applies_rules());
    }
}
