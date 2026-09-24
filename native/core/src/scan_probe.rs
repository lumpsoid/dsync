//! Splits what a scan costs into the platform's floor and this project's
//! own code (task 1a341e), by walking one tree once per
//! [`ScanProbeLayer`], each rung one named step more than the one below.
//!
//! Instrumentation, not a feature: nothing in a run calls it; the head's
//! diagnostics page does, on the device being measured. It reports no
//! failures - an unreadable folder is passed over silently by the walking
//! rungs - because correctness is the scanner's job and this measures cost.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use dsync_domain::{
    Archive, ArchiveCommit, CaseFolding, Jobs, RelPath, RuleSet, ScanEntry, ScanProbeLayer,
    ScanProbeLayerResult, ScanProbePass, ScanProbeReport, is_temp_file_name,
};

use crate::scan_pool;
use crate::scanner::{Scanner, UnreadableRoot, child_path, stat};

/// A probe with the same `jobs` and `folding` a real scan of this replica
/// would use, so the scanner rungs are the real thing and the §16 check's
/// cost lands where the report says it does.
#[derive(Clone, Copy, Debug)]
pub struct ScanProbe {
    jobs: Jobs,
    folding: CaseFolding,
}

impl ScanProbe {
    pub fn new(jobs: Jobs, folding: CaseFolding) -> ScanProbe {
        ScanProbe { jobs, folding }
    }

    /// Climbs the ladder over `root` `passes` times, back to back: a later
    /// pass much faster than the first says the cost is I/O and page cache,
    /// one that matches says it is CPU. `rules` should be the run's own, so
    /// the rules rung measures these patterns against this tree.
    pub fn run(
        &self,
        root: &Path,
        rules: &RuleSet,
        passes: usize,
    ) -> Result<ScanProbeReport, UnreadableRoot> {
        let root = fs::canonicalize(root).map_err(|source| UnreadableRoot {
            root: root.to_path_buf(),
            source,
        })?;
        let passes = (0..passes)
            .map(|index| self.pass(index, &root, rules))
            .collect::<Result<_, _>>()?;
        Ok(ScanProbeReport { root, passes })
    }

    fn pass(
        &self,
        index: usize,
        root: &Path,
        rules: &RuleSet,
    ) -> Result<ScanProbePass, UnreadableRoot> {
        let mut layers: Vec<ScanProbeLayerResult> = [
            ScanProbeLayer::List,
            ScanProbeLayer::Stat,
            ScanProbeLayer::Rules,
        ]
        .into_iter()
        .map(|layer| self.walk_layer(layer, root, rules))
        .collect();

        // The empty-archive rung runs first because it produces the warm
        // archive: what it reports is exactly what a committed archive
        // would hold, so the warm rung takes the fast path for every file.
        let scanner = Scanner::new(self.jobs, self.folding);
        let started = Instant::now();
        let cold = scanner.scan(root, &Archive::default(), rules)?;
        let cold_elapsed = started.elapsed();
        let warm_archive = Archive::replay(cold.entries.iter().filter_map(|entry| {
            let file = entry.status.file()?;
            Some(ArchiveCommit::Upsert {
                path: entry.path.clone(),
                file: *file,
            })
        }));
        let started = Instant::now();
        let warm = scanner.scan(root, &warm_archive, rules)?;
        let warm_elapsed = started.elapsed();

        layers.push(scan_rung(
            ScanProbeLayer::ScanWarmArchive,
            warm_elapsed,
            &warm.entries,
        ));
        layers.push(scan_rung(
            ScanProbeLayer::ScanEmptyArchive,
            cold_elapsed,
            &cold.entries,
        ));
        Ok(ScanProbePass { index, layers })
    }

    /// One walking rung: shaped like the scanner's walk (a sorted listing
    /// per folder, children typed by the listing, links never followed,
    /// then every stat on the pool), doing only what `layer` says.
    fn walk_layer(
        &self,
        layer: ScanProbeLayer,
        root: &Path,
        rules: &RuleSet,
    ) -> ScanProbeLayerResult {
        let started = Instant::now();
        let mut tally = Tally::default();
        walk(root, None, layer, rules, &mut tally);
        let mut bytes = 0;
        if layer.stats_files() {
            let metas = scan_pool::run(self.jobs, &tally.files, || (), |(), file| stat(file));
            // Every field is folded in, so the rung consumes what it asked
            // the OS for.
            let mut folded = 0i64;
            for meta in metas.into_iter().flatten() {
                bytes += meta.size;
                folded ^= meta.mtime_us ^ i64::from(meta.mode);
            }
            std::hint::black_box(folded);
        }
        ScanProbeLayerResult {
            layer,
            elapsed: started.elapsed(),
            files: tally.files.len() as u64,
            directories: Some(tally.directories),
            bytes,
        }
    }
}

#[derive(Default)]
struct Tally {
    files: Vec<PathBuf>,
    directories: u64,
}

fn walk(
    dir: &Path,
    parent: Option<&RelPath>,
    layer: ScanProbeLayer,
    rules: &RuleSet,
    tally: &mut Tally,
) {
    let Ok(listing) = fs::read_dir(dir) else {
        return;
    };
    let mut children: Vec<_> = listing
        .filter_map(|entry| {
            let entry = entry.ok()?;
            Some((entry.file_name(), entry.file_type().ok()?))
        })
        .collect();
    children.sort_by(|a, b| a.0.cmp(&b.0));

    for (name, kind) in children {
        let path = if layer.applies_rules() {
            let Some(path) = name.to_str().and_then(|text| {
                let path = child_path(parent, text).ok()?;
                (!rules.ignores(&path) && !is_temp_file_name(text)).then_some(path)
            }) else {
                continue;
            };
            Some(path)
        } else {
            None
        };
        let source = dir.join(&name);
        if kind.is_dir() {
            tally.directories += 1;
            walk(&source, path.as_ref(), layer, rules, tally);
        } else if kind.is_file() {
            tally.files.push(source);
        }
    }
}

/// A scanner rung, counted from what the scan reported. No directory
/// count: a scan does not report the folders it went through.
fn scan_rung(
    layer: ScanProbeLayer,
    elapsed: std::time::Duration,
    entries: &[ScanEntry],
) -> ScanProbeLayerResult {
    let live = entries.iter().filter_map(|entry| entry.status.file());
    let (files, bytes) = live.fold((0, 0), |(files, bytes), file| {
        (files + 1, bytes + file.meta.size)
    });
    ScanProbeLayerResult {
        layer,
        elapsed,
        files,
        directories: None,
        bytes,
    }
}
