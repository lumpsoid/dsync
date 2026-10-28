//! A line diff of two texts, in hunks with word emphasis (the review's diff
//! page). Computed by `similar`, whose types stop here: everything past the
//! domain sees only the tree below.

use std::time::{Duration, Instant};

use similar::{Algorithm, ChangeTag, DiffOp};

use crate::file_text::FileText;

/// Unchanged lines kept around each change; changes closer than twice this
/// share a hunk.
const CONTEXT_LINES: usize = 3;

/// The most lines a side of a `Changed` block may have and still get word
/// emphasis; past it the block is a rewritten wall and emphasis is noise.
const MAX_EMPHASIZED_LINES: usize = 50;

/// What changed between two texts.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum TextDiff {
    /// Same text. `bytes_differ`: only line endings, a final newline or a
    /// BOM differ.
    Identical { bytes_differ: bool },
    /// The changes, in order; never empty.
    Hunks(Vec<Hunk>),
}

/// A run of changes with their context. `old_start` / `new_start` are the
/// 1-based line numbers of the hunk's first line on each side; a line's
/// number is its start plus its position among that side's lines in the
/// hunk. A side with no lines in the hunk still has the start its next line
/// would have (an insert into an empty file starts at 1), so the unchanged
/// lines between two hunks are `next.old_start - (old_start + old lines)`,
/// the same on either side.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Hunk {
    pub old_start: u32,
    pub new_start: u32,
    pub blocks: Vec<Block>,
}

/// Part of a hunk.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Block {
    /// Context, the same on both sides.
    Same(Vec<String>),
    /// A replaced run: `old` lines became `new` lines; either may be empty
    /// (a pure delete or insert). One block, not interleaved -/+ lines, so a
    /// side-by-side layout pairs old[i] with new[i] and a unified layout
    /// prints old then new: one shape, two renderings.
    Changed { old: Vec<Line>, new: Vec<Line> },
}

/// A changed line as spans; `emphasized` marks the words that differ from
/// its paired line on the other side. Never empty: a line without emphasis
/// is one plain span (an empty line is one empty span).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Line {
    pub spans: Vec<Span>,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Span {
    pub text: String,
    pub emphasized: bool,
}

impl TextDiff {
    /// Diffs `old` against `new` by lines. A missing side diffs as empty
    /// text, so `None` against `None` (or against an empty file) is
    /// `Identical { bytes_differ: false }`. Past `deadline` the diff turns
    /// coarser but stays correct: replaying it on `old` still gives `new`.
    pub fn between(old: Option<&FileText>, new: Option<&FileText>, deadline: Duration) -> TextDiff {
        let empty = FileText::empty();
        let old = old.unwrap_or(&empty);
        let new = new.unwrap_or(&empty);
        let old_lines = old.lines();
        let new_lines = new.lines();
        if old_lines == new_lines {
            return TextDiff::Identical {
                bytes_differ: old.bytes_differ(new),
            };
        }
        let until = Instant::now().checked_add(deadline);
        let mut config = similar::TextDiff::configure();
        config.algorithm(Algorithm::Myers);
        if let Some(until) = until {
            config.deadline(until);
        }
        let diff = config.diff_slices(&old_lines, &new_lines);
        let hunks = diff
            .grouped_ops(CONTEXT_LINES)
            .iter()
            .map(|group| hunk(group, &old_lines, &new_lines, until))
            .collect();
        TextDiff::Hunks(hunks)
    }
}

/// One group of `similar` ops as a hunk: equal ops become `Same`, and every
/// run of non-equal ops (delete, insert, replace) merges into one `Changed`.
fn hunk(group: &[DiffOp], old: &[&str], new: &[&str], until: Option<Instant>) -> Hunk {
    let first = &group[0];
    let mut blocks = Vec::new();
    let mut changed_old: Vec<&str> = Vec::new();
    let mut changed_new: Vec<&str> = Vec::new();
    for op in group {
        if let DiffOp::Equal { .. } = op {
            if !changed_old.is_empty() || !changed_new.is_empty() {
                blocks.push(changed(&changed_old, &changed_new, until));
                changed_old.clear();
                changed_new.clear();
            }
            let same = old[op.old_range()].iter().map(|l| l.to_string()).collect();
            blocks.push(Block::Same(same));
        } else {
            changed_old.extend_from_slice(&old[op.old_range()]);
            changed_new.extend_from_slice(&new[op.new_range()]);
        }
    }
    if !changed_old.is_empty() || !changed_new.is_empty() {
        blocks.push(changed(&changed_old, &changed_new, until));
    }
    Hunk {
        old_start: line_number(first.old_range().start),
        new_start: line_number(first.new_range().start),
        blocks,
    }
}

/// A `Changed` block: old[i] and new[i] emphasized against each other while
/// both exist and neither side is over `MAX_EMPHASIZED_LINES`; the rest plain.
fn changed(old: &[&str], new: &[&str], until: Option<Instant>) -> Block {
    let mut old_lines: Vec<Line> = old.iter().map(|l| plain(l)).collect();
    let mut new_lines: Vec<Line> = new.iter().map(|l| plain(l)).collect();
    if old.len() <= MAX_EMPHASIZED_LINES && new.len() <= MAX_EMPHASIZED_LINES {
        for (i, (a, b)) in old.iter().zip(new).enumerate() {
            (old_lines[i], new_lines[i]) = emphasized(a, b, until);
        }
    }
    Block::Changed {
        old: old_lines,
        new: new_lines,
    }
}

/// `old` and `new` as spans, the words that differ between them emphasized.
fn emphasized(old: &str, new: &str, until: Option<Instant>) -> (Line, Line) {
    let mut config = similar::TextDiff::configure();
    if let Some(until) = until {
        config.deadline(until);
    }
    let diff = config.diff_words(old, new);
    let mut old_spans = Vec::new();
    let mut new_spans = Vec::new();
    for op in diff.ops() {
        for change in diff.iter_changes(op) {
            let text = change.value();
            match change.tag() {
                ChangeTag::Equal => {
                    push(&mut old_spans, text, false);
                    push(&mut new_spans, text, false);
                }
                ChangeTag::Delete => push(&mut old_spans, text, true),
                ChangeTag::Insert => push(&mut new_spans, text, true),
            }
        }
    }
    (line(old_spans), line(new_spans))
}

/// Appends `text` to `spans`, joining the last span when the emphasis is the
/// same.
fn push(spans: &mut Vec<Span>, text: &str, emphasized: bool) {
    match spans.last_mut() {
        Some(last) if last.emphasized == emphasized => last.text.push_str(text),
        _ => spans.push(Span {
            text: text.to_string(),
            emphasized,
        }),
    }
}

fn line(spans: Vec<Span>) -> Line {
    if spans.is_empty() {
        return plain("");
    }
    Line { spans }
}

fn plain(text: &str) -> Line {
    Line {
        spans: vec![Span {
            text: text.to_string(),
            emphasized: false,
        }],
    }
}

/// The 1-based number of the line at 0-based `index`. A text has at most
/// `PeekLimits::max_bytes` lines, far below `u32::MAX`; it saturates anyway.
fn line_number(index: usize) -> u32 {
    u32::try_from(index + 1).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEADLINE: Duration = Duration::from_millis(200);

    fn text(s: &str) -> FileText {
        FileText::decode(s.as_bytes().to_vec()).unwrap()
    }

    fn numbered(n: usize) -> Vec<String> {
        (1..=n).map(|i| format!("line {i}")).collect()
    }

    fn joined(lines: &[String]) -> String {
        lines.iter().map(|l| format!("{l}\n")).collect()
    }

    fn line_text(line: &Line) -> String {
        line.spans.iter().map(|s| s.text.as_str()).collect()
    }

    fn hunks(diff: &TextDiff) -> &[Hunk] {
        match diff {
            TextDiff::Hunks(hunks) => hunks,
            other => panic!("expected hunks, got {other:?}"),
        }
    }

    fn old_len(hunk: &Hunk) -> usize {
        hunk.blocks
            .iter()
            .map(|b| match b {
                Block::Same(lines) => lines.len(),
                Block::Changed { old, .. } => old.len(),
            })
            .sum()
    }

    /// The unchanged lines between `a` and `b` as the head derives them,
    /// from the starts and the block lengths.
    fn gap(a: &Hunk, b: &Hunk) -> u32 {
        b.old_start - (a.old_start + old_len(a) as u32)
    }

    /// Rebuilds both texts from `old` and the hunks: the gaps come from
    /// `old` (they are unchanged), everything else from the blocks. Checks
    /// that each gap is the same length on both sides, that no hunk is
    /// empty, and that context and changes sit at their starts.
    fn assert_replays(old: &str, new: &str, diff: &TextDiff) {
        let old_lines = text(old)
            .lines()
            .iter()
            .map(|l| l.to_string())
            .collect::<Vec<_>>();
        let new_lines = text(new)
            .lines()
            .iter()
            .map(|l| l.to_string())
            .collect::<Vec<_>>();
        let mut rebuilt_old: Vec<String> = Vec::new();
        let mut rebuilt_new: Vec<String> = Vec::new();
        let hunks = hunks(diff);
        assert!(!hunks.is_empty());
        for hunk in hunks {
            assert!(!hunk.blocks.is_empty());
            let old_gap = hunk.old_start as usize - 1 - rebuilt_old.len();
            let new_gap = hunk.new_start as usize - 1 - rebuilt_new.len();
            assert_eq!(old_gap, new_gap, "a gap differs between sides");
            let unchanged = &old_lines[rebuilt_old.len()..rebuilt_old.len() + old_gap];
            rebuilt_old.extend_from_slice(unchanged);
            rebuilt_new.extend_from_slice(unchanged);
            for block in &hunk.blocks {
                match block {
                    Block::Same(lines) => {
                        assert!(lines.len() <= 2 * CONTEXT_LINES);
                        rebuilt_old.extend_from_slice(lines);
                        rebuilt_new.extend_from_slice(lines);
                    }
                    Block::Changed { old, new } => {
                        assert!(!old.is_empty() || !new.is_empty());
                        rebuilt_old.extend(old.iter().map(line_text));
                        rebuilt_new.extend(new.iter().map(line_text));
                    }
                }
            }
        }
        let tail = &old_lines[rebuilt_old.len()..];
        rebuilt_old.extend_from_slice(tail);
        rebuilt_new.extend_from_slice(tail);
        assert_eq!(rebuilt_old, old_lines);
        assert_eq!(rebuilt_new, new_lines);
    }

    fn diff(old: &str, new: &str) -> TextDiff {
        let diff = TextDiff::between(Some(&text(old)), Some(&text(new)), DEADLINE);
        assert_replays(old, new, &diff);
        diff
    }

    fn same(lines: &[String]) -> Block {
        Block::Same(lines.to_vec())
    }

    fn changed_plain(old: &[&str], new: &[&str]) -> Block {
        Block::Changed {
            old: old.iter().map(|l| plain(l)).collect(),
            new: new.iter().map(|l| plain(l)).collect(),
        }
    }

    fn span(text: &str, emphasized: bool) -> Span {
        Span {
            text: text.to_string(),
            emphasized,
        }
    }

    fn has_emphasis(block: &Block) -> bool {
        match block {
            Block::Same(_) => false,
            Block::Changed { old, new } => old
                .iter()
                .chain(new)
                .any(|l| l.spans.iter().any(|s| s.emphasized)),
        }
    }

    /// `n` numbered lines with lines at the 1-based `at` replaced.
    fn edited(n: usize, at: &[usize]) -> (String, String) {
        let old = numbered(n);
        let mut new = old.clone();
        for &i in at {
            new[i - 1] = format!("changed {i}");
        }
        (joined(&old), joined(&new))
    }

    #[test]
    fn equal_texts_are_identical() {
        let t = text("a\nb\n");
        assert_eq!(
            TextDiff::between(Some(&t), Some(&t), DEADLINE),
            TextDiff::Identical {
                bytes_differ: false
            }
        );
    }

    #[test]
    fn line_endings_bom_and_final_newline_are_identical_with_bytes_differing() {
        let differing = TextDiff::Identical { bytes_differ: true };
        let between =
            |a: &str, b: &str| TextDiff::between(Some(&text(a)), Some(&text(b)), DEADLINE);
        assert_eq!(between("a\r\nb\r\n", "a\nb\n"), differing);
        assert_eq!(between("\u{feff}a\nb\n", "a\nb\n"), differing);
        assert_eq!(between("a\nb", "a\nb\n"), differing);
    }

    #[test]
    fn a_missing_side_diffs_as_empty() {
        let t = text("a\nb\n");
        assert_eq!(
            TextDiff::between(None, Some(&t), DEADLINE),
            TextDiff::Hunks(vec![Hunk {
                old_start: 1,
                new_start: 1,
                blocks: vec![changed_plain(&[], &["a", "b"])],
            }])
        );
        assert_eq!(
            TextDiff::between(Some(&t), None, DEADLINE),
            TextDiff::Hunks(vec![Hunk {
                old_start: 1,
                new_start: 1,
                blocks: vec![changed_plain(&["a", "b"], &[])],
            }])
        );
        assert_replays("", "a\nb\n", &TextDiff::between(None, Some(&t), DEADLINE));
    }

    /// The block `edited` makes of line `i`: the first word emphasized.
    fn edit_of(i: usize) -> Block {
        Block::Changed {
            old: vec![Line {
                spans: vec![span("line", true), span(&format!(" {i}"), false)],
            }],
            new: vec![Line {
                spans: vec![span("changed", true), span(&format!(" {i}"), false)],
            }],
        }
    }

    #[test]
    fn nothing_against_nothing_or_empty_is_identical() {
        let identical = TextDiff::Identical {
            bytes_differ: false,
        };
        assert_eq!(TextDiff::between(None, None, DEADLINE), identical);
        assert_eq!(
            TextDiff::between(None, Some(&text("")), DEADLINE),
            identical
        );
    }

    #[test]
    fn one_changed_line_in_a_hundred_is_one_hunk_with_three_lines_around() {
        let (old, new) = edited(100, &[50]);
        let lines = numbered(100);
        assert_eq!(
            diff(&old, &new),
            TextDiff::Hunks(vec![Hunk {
                old_start: 47,
                new_start: 47,
                blocks: vec![same(&lines[46..49]), edit_of(50), same(&lines[50..53]),],
            }])
        );
    }

    #[test]
    fn a_change_at_the_first_line_has_no_context_before() {
        let (old, new) = edited(100, &[1]);
        let lines = numbered(100);
        assert_eq!(
            diff(&old, &new),
            TextDiff::Hunks(vec![Hunk {
                old_start: 1,
                new_start: 1,
                blocks: vec![edit_of(1), same(&lines[1..4]),],
            }])
        );
    }

    #[test]
    fn a_change_at_the_last_line_has_no_context_after() {
        let (old, new) = edited(100, &[100]);
        let lines = numbered(100);
        assert_eq!(
            diff(&old, &new),
            TextDiff::Hunks(vec![Hunk {
                old_start: 97,
                new_start: 97,
                blocks: vec![same(&lines[96..99]), edit_of(100),],
            }])
        );
    }

    #[test]
    fn far_apart_changes_are_two_hunks_with_the_gap_between() {
        let (old, new) = edited(100, &[10, 30]);
        let d = diff(&old, &new);
        let hunks = hunks(&d);
        assert_eq!(hunks.len(), 2);
        assert_eq!((hunks[0].old_start, hunks[1].old_start), (7, 27));
        // Lines 14..=26 are between the hunks.
        assert_eq!(gap(&hunks[0], &hunks[1]), 13);
    }

    #[test]
    fn changes_split_into_hunks_only_past_twice_the_context() {
        // Lines 11..=16 between: 6 = 2 * context, one hunk.
        let (old, new) = edited(100, &[10, 17]);
        assert_eq!(hunks(&diff(&old, &new)).len(), 1);
        // Lines 11..=17 between: 7, two hunks with one line hidden.
        let (old, new) = edited(100, &[10, 18]);
        let d = diff(&old, &new);
        let hunks = hunks(&d);
        assert_eq!(hunks.len(), 2);
        assert_eq!(gap(&hunks[0], &hunks[1]), 1);
    }

    #[test]
    fn an_insert_shifts_the_new_start_of_later_hunks() {
        let old = numbered(40);
        let mut new = old.clone();
        new.insert(5, "inserted a".to_string());
        new.insert(6, "inserted b".to_string());
        new[31] = "changed".to_string();
        let d = diff(&joined(&old), &joined(&new));
        let hunks = hunks(&d);
        assert_eq!(hunks.len(), 2);
        assert_eq!(
            hunks[0].blocks[1],
            changed_plain(&[], &["inserted a", "inserted b"])
        );
        assert_eq!(hunks[1].new_start, hunks[1].old_start + 2);
    }

    #[test]
    fn a_delete_and_insert_run_is_one_changed_block() {
        // `similar`'s line diff already folds a delete before an insert into
        // a replace, so build the ops by hand to see the merge itself.
        let old = ["a", "b", "c", "d"];
        let new = ["a", "x", "y", "d"];
        let group = [
            DiffOp::Equal {
                old_index: 0,
                new_index: 0,
                len: 1,
            },
            DiffOp::Delete {
                old_index: 1,
                old_len: 2,
                new_index: 1,
            },
            DiffOp::Insert {
                old_index: 3,
                new_index: 1,
                new_len: 1,
            },
            DiffOp::Replace {
                old_index: 3,
                old_len: 0,
                new_index: 2,
                new_len: 1,
            },
            DiffOp::Equal {
                old_index: 3,
                new_index: 3,
                len: 1,
            },
        ];
        let hunk = hunk(&group, &old, &new, None);
        assert_eq!(hunk.blocks.len(), 3);
        let Block::Changed { old, new } = &hunk.blocks[1] else {
            panic!("expected a changed block");
        };
        assert_eq!(old.iter().map(line_text).collect::<Vec<_>>(), ["b", "c"]);
        assert_eq!(new.iter().map(line_text).collect::<Vec<_>>(), ["x", "y"]);
    }

    #[test]
    fn a_replaced_line_emphasizes_exactly_the_changed_word() {
        let d = diff(
            "keep\nthe quick brown fox\nkeep\n",
            "keep\nthe slow brown fox\nkeep\n",
        );
        assert_eq!(
            hunks(&d)[0].blocks[1],
            Block::Changed {
                old: vec![Line {
                    spans: vec![
                        span("the ", false),
                        span("quick", true),
                        span(" brown fox", false)
                    ],
                }],
                new: vec![Line {
                    spans: vec![
                        span("the ", false),
                        span("slow", true),
                        span(" brown fox", false)
                    ],
                }],
            }
        );
    }

    #[test]
    fn surplus_lines_of_a_changed_block_are_plain() {
        let d = diff(
            "keep\nold one\nold two\nkeep\n",
            "keep\nnew one\nnew two\nextra line\nkeep\n",
        );
        let Block::Changed { old, new } = &hunks(&d)[0].blocks[1] else {
            panic!("expected a changed block");
        };
        assert_eq!((old.len(), new.len()), (2, 3));
        assert_eq!(old[0].spans, vec![span("old", true), span(" one", false)]);
        assert_eq!(new[2], plain("extra line"));
    }

    fn rewritten(n: usize) -> TextDiff {
        let old: String = (0..n).map(|i| format!("row {i} alpha\n")).collect();
        let new: String = (0..n).map(|i| format!("row {i} beta\n")).collect();
        let old = format!("top\n{old}bottom\n");
        let new = format!("top\n{new}bottom\n");
        diff(&old, &new)
    }

    #[test]
    fn a_block_over_fifty_lines_has_no_emphasis() {
        let d = rewritten(MAX_EMPHASIZED_LINES + 1);
        let block = &hunks(&d)[0].blocks[1];
        assert!(!has_emphasis(block));
        let Block::Changed { old, new } = block else {
            panic!("expected a changed block");
        };
        assert_eq!((old.len(), new.len()), (51, 51));
        assert!(old.iter().chain(new).all(|l| l.spans.len() == 1));
    }

    #[test]
    fn a_block_of_fifty_lines_has_emphasis() {
        let d = rewritten(MAX_EMPHASIZED_LINES);
        let Block::Changed { old, .. } = &hunks(&d)[0].blocks[1] else {
            panic!("expected a changed block");
        };
        assert_eq!(old.len(), 50);
        assert_eq!(
            old[0].spans,
            vec![span("row 0 ", false), span("alpha", true)]
        );
    }

    /// Lines from a small alphabet in an order a linear congruential
    /// generator picks: little in common in order, much in common as lines,
    /// which is Myers' worst case.
    fn scrambled(seed: u64, n: usize) -> String {
        let mut state = seed;
        (0..n)
            .map(|_| {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                format!("token {}\n", (state >> 33) % 64)
            })
            .collect()
    }

    /// 200,000 lines a side (about 1.6 MB, under the peek cap). Uncapped this
    /// took ~10 s in a debug build, so the bound below fails without the
    /// deadline.
    #[test]
    fn a_pathological_pair_finishes_near_the_deadline_and_still_replays() {
        let old = scrambled(1, 200_000);
        let new = scrambled(2, 200_000);
        let started = Instant::now();
        let d = TextDiff::between(
            Some(&text(&old)),
            Some(&text(&new)),
            Duration::from_millis(50),
        );
        let took = started.elapsed();
        assert!(took < Duration::from_secs(2), "took {took:?}");
        assert_replays(&old, &new, &d);
    }
}
