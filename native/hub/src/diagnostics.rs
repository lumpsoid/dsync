//! What the head asks about a folder before it syncs one: whether it is
//! usable at all (SPEC §3), what the ignore rules keep of it (SPEC §9),
//! and what scanning it costs.

use std::path::PathBuf;

use dsync_core::{
    ScanProbe, check_root_access, list_filter_folder, preview_filters_at, probe_case_folding,
};
use dsync_domain::{Glob, RelPath, RootKind, RuleSet};

use crate::dispatch::{Handled, Hub, blocking, text};
use crate::signals::ReplyResult;
use crate::views::{FilterPreviewView, FilterRowView, ScanProbeView};

impl Hub {
    pub(crate) async fn preview_filters(&self, root: String, ignore: &[String]) -> Handled {
        let rules = ignore_rules(ignore)?;
        blocking(move || {
            let report = preview_filters_at(&PathBuf::from(root), &rules).map_err(text)?;
            Ok(ReplyResult::FilterPreview(FilterPreviewView::from(&report)))
        })
        .await
    }

    pub(crate) async fn list_filter_folder(
        &self,
        root: String,
        folder: Option<String>,
        ignore: &[String],
    ) -> Handled {
        let rules = ignore_rules(ignore)?;
        let folder = folder
            .map(|path| RelPath::parse(&path))
            .transpose()
            .map_err(text)?;
        blocking(move || {
            let rows =
                list_filter_folder(&PathBuf::from(root), folder.as_ref(), &rules).map_err(text)?;
            Ok(ReplyResult::FilterFolder(
                rows.iter().map(FilterRowView::from).collect(),
            ))
        })
        .await
    }

    pub(crate) async fn check_folder(&self, path: String) -> Handled {
        blocking(move || {
            Ok(ReplyResult::FolderChecked {
                refusal: check_root_access(RootKind::Folder, &PathBuf::from(path))
                    .err()
                    .map(text),
            })
        })
        .await
    }

    /// The scan's layers over `root`, with the jobs and case folding a
    /// real scan of it would use.
    pub(crate) async fn probe_scan(&self, root: String, ignore: &[String], passes: u32) -> Handled {
        let rules = ignore_rules(ignore)?;
        let jobs = self.tuning.scan_jobs;
        blocking(move || {
            let root = PathBuf::from(root);
            let probe = ScanProbe::new(jobs, probe_case_folding(&root));
            let passes = usize::try_from(passes).map_err(text)?;
            let report = probe.run(&root, &rules, passes).map_err(text)?;
            Ok(ReplyResult::ScanProbe(ScanProbeView::from(&report)))
        })
        .await
    }
}

/// One ignore pattern checked on its own, as the head's filter page
/// takes it in.
pub(crate) fn check_ignore_pattern(pattern: &str) -> Handled {
    Glob::new(pattern).map_err(text)?;
    Ok(ReplyResult::Done)
}

/// `--ignore`-style patterns as rules.
pub(crate) fn ignore_rules(patterns: &[String]) -> Result<RuleSet, String> {
    let ignore = patterns
        .iter()
        .map(|pattern| Glob::new(pattern).map_err(text))
        .collect::<Result<_, _>>()?;
    Ok(RuleSet::new(ignore, Vec::new()))
}
