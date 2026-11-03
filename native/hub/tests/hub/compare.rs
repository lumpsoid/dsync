//! A review row's two files compared through the hub: asked by row index
//! while the review is open, served by the run's decider, and cancelled
//! or failed when the head moves on first.
//!
//! The tests that need a read held in flight replace the row's file on
//! side A with a FIFO after the plan is shown: the peek's open waits for a
//! writer. Linux counts a reader still waiting in `open` as the FIFO's
//! reader, so a non-blocking open of the write end succeeds exactly when a
//! read has started - the probe these tests use - and holding that write
//! end open keeps the read waiting for bytes until it is dropped.

use dsync_domain::{PeekLimits, Tuning};
use hub::signals::{CoreCommand, ReplyResult, RowRef, RunIntent};
use hub::views::{BlockView, ComparedView, ComparisonView, LineView, OfferView, SideView};

use crate::run::{GUARD, ended, is, local_profile, plan_id, row, start, steer};
use crate::support::{FoldedRunView, Head, write};

const REVIEW_CLOSED: &str = "the review is no longer open";
const CANCELLED: &str = "cancelled";

fn compare(session: u64, plan_id: u64, row: RowRef) -> CoreCommand {
    CoreCommand::CompareRow {
        session,
        plan_id,
        row,
    }
}

fn action(index: u32) -> RowRef {
    RowRef::Action { index }
}

/// Where the plan in `view` has the conflict on `path`.
fn conflict(view: &FoldedRunView, path: &str) -> RowRef {
    let at = view
        .conflicts
        .iter()
        .position(|row| row.conflict.path == path)
        .unwrap_or_else(|| panic!("{path} is a conflict"));
    RowRef::Conflict {
        index: u32::try_from(at).unwrap_or_else(|error| panic!("{error}")),
    }
}

fn failure(result: ReplyResult) -> String {
    match result {
        ReplyResult::Failed { message } => message,
        _ => panic!("the compare should have failed"),
    }
}

/// The compared path, both sides' sizes and the verdict.
fn compared(result: ReplyResult) -> (String, Option<u64>, Option<u64>, ComparedView) {
    match result {
        ReplyResult::Comparison(ComparisonView::Compared {
            path,
            old_side,
            new_side,
            verdict,
        }) => (path, old_side.size, new_side.size, verdict),
        ReplyResult::Failed { message } => panic!("the compare failed: {message}"),
        _ => panic!("expected a comparison"),
    }
}

fn text(line: &LineView) -> String {
    line.spans.iter().map(|span| span.text.as_str()).collect()
}

fn texts(lines: &[LineView]) -> Vec<String> {
    lines.iter().map(text).collect()
}

/// The hunks' blocks, each as its kind and its lines' text: `=` same,
/// `-` old, `+` new.
fn blocks(verdict: &ComparedView) -> Vec<(u32, u32, Vec<String>)> {
    let ComparedView::Hunks(hunks) = verdict else {
        panic!("expected hunks");
    };
    hunks
        .iter()
        .map(|hunk| {
            let lines = hunk
                .blocks
                .iter()
                .flat_map(|block| match block {
                    BlockView::Same(lines) => lines.iter().map(|l| format!("={l}")).collect(),
                    BlockView::Changed {
                        old_lines,
                        new_lines,
                    } => texts(old_lines)
                        .into_iter()
                        .map(|l| format!("-{l}"))
                        .chain(texts(new_lines).into_iter().map(|l| format!("+{l}")))
                        .collect::<Vec<_>>(),
                })
                .collect();
            (hunk.old_start, hunk.new_start, lines)
        })
        .collect()
}

async fn review(head: &mut Head, session: u64) -> FoldedRunView {
    head.run_until(session, is("reviewing"))
        .await
        .pop()
        .unwrap_or_else(|| unreachable!("stopped at it"))
}

#[tokio::test]
async fn a_review_row_s_two_files_compare_as_a_line_diff() {
    let mut head = Head::new("studio").await;
    write(&head.path("a/new.txt"), "hello\n");
    write(&head.path("a/both.txt"), "one\ntwo\n");
    write(&head.path("b/both.txt"), "one\nTWO\n");
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", false, None, GUARD)).await;
    let view = review(&mut head, session).await;
    let plan = plan_id(&view);
    let new = row(&view, "new.txt");
    let both = conflict(&view, "both.txt");
    assert!(matches!(
        view.plan[new as usize].proposal.offer,
        OfferView::Readable
    ));
    assert!(matches!(view.conflicts[0].offer, OfferView::Readable));

    // A copy onto no file: the old side has none, the whole file is added.
    let (path, old, new_size, verdict) =
        compared(head.ok(compare(session, plan, action(new))).await.1);
    assert_eq!((path.as_str(), old, new_size), ("new.txt", None, Some(6)));
    assert_eq!(blocks(&verdict), [(1, 1, vec!["+hello".to_owned()])]);

    // A conflict: A is old, B is new, the changed word emphasized.
    let (path, old, new_size, verdict) = compared(head.ok(compare(session, plan, both)).await.1);
    assert_eq!(
        (path.as_str(), old, new_size),
        ("both.txt", Some(8), Some(8))
    );
    assert_eq!(
        blocks(&verdict),
        [(
            1,
            1,
            vec!["=one".to_owned(), "-two".to_owned(), "+TWO".to_owned()]
        )]
    );
    let ComparedView::Hunks(hunks) = &verdict else {
        unreachable!("checked");
    };
    let BlockView::Changed {
        new_lines: changed, ..
    } = &hunks[0].blocks[1]
    else {
        panic!("expected the changed block");
    };
    assert!(changed[0].spans.iter().any(|span| span.emphasized));

    // No such row: nothing to compare, and no failure.
    assert!(matches!(
        head.ok(compare(session, plan, action(99))).await.1,
        ReplyResult::Comparison(ComparisonView::NotComparable)
    ));

    // A row of another plan than the one under review: not this review's.
    assert_eq!(
        failure(head.ask(compare(session, plan + 1, action(new))).await.1),
        REVIEW_CLOSED
    );

    head.ok(steer(session, RunIntent::Confirm { plan_id: plan }))
        .await;
    head.run_until(session, ended).await;
    let after = failure(head.ask(compare(session, plan, action(new))).await.1);
    assert!(after.contains("no run"), "{after}");
}

/// A session waiting on a resume has no review open: a compare fails
/// rather than waits.
#[tokio::test]
async fn a_compare_with_no_review_open_fails() {
    let mut head = Head::new("studio").await;
    let (session, _) = head.ok(start("nothing-here", false, None, GUARD)).await;
    head.run_until(session, is("failed")).await;
    assert_eq!(
        failure(head.ask(compare(session, 1, action(0))).await.1),
        REVIEW_CLOSED
    );
    head.ok(steer(session, RunIntent::Close)).await;
}

/// The row offers what the compare gives: both judged by the hub's own
/// tuning, here a cap of 8 bytes.
#[tokio::test]
async fn row_offers_and_the_compare_agree_under_the_hub_s_tuning() {
    let tuning = Tuning {
        peek: PeekLimits {
            max_bytes: 8,
            ..Tuning::DEFAULT.peek
        },
        ..Tuning::DEFAULT
    };
    let mut head = Head::with_tuning("studio", tuning).await;
    write(&head.path("a/big.txt"), "0123456789\n");
    write(&head.path("a/small.txt"), "hi\n");
    std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
    local_profile(&head, "local", "a", "b");
    let (session, _) = head.ok(start("local", false, None, GUARD)).await;
    let view = review(&mut head, session).await;
    let (big, small) = (row(&view, "big.txt"), row(&view, "small.txt"));
    let plan = plan_id(&view);

    assert!(matches!(
        view.plan[big as usize].proposal.offer,
        OfferView::TooLarge {
            side: SideView::A,
            size: 11
        }
    ));
    let (_, _, _, verdict) = compared(head.ok(compare(session, plan, action(big))).await.1);
    assert!(matches!(
        verdict,
        ComparedView::TooLarge {
            side: SideView::A,
            size: 11
        }
    ));

    assert!(matches!(
        view.plan[small as usize].proposal.offer,
        OfferView::Readable
    ));
    let (_, _, _, verdict) = compared(head.ok(compare(session, plan, action(small))).await.1);
    assert_eq!(blocks(&verdict), [(1, 1, vec!["+hi".to_owned()])]);
    head.ok(steer(session, RunIntent::Stop)).await;
    head.run_until(session, ended).await;
}

#[cfg(target_os = "linux")]
mod held {
    use std::ffi::CString;
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::Path;
    use std::time::Duration;

    use hub::signals::{CoreCommand, ReplyResult, RunIntent};

    use super::{
        CANCELLED, REVIEW_CLOSED, action, blocks, compare, compared, failure, review, row,
    };
    use crate::run::{GUARD, ended, is, local_profile, plan_id, start, steer};
    use crate::support::{Head, read, with_deadline, write};

    /// Replaces `path` with a FIFO: a read of it waits for a writer.
    fn fifo(path: &Path) {
        std::fs::remove_file(path).unwrap_or_else(|error| panic!("{error}"));
        let name =
            CString::new(path.as_os_str().as_bytes()).unwrap_or_else(|error| panic!("{error}"));
        // SAFETY: `name` is a valid NUL-terminated path for the call.
        let made = unsafe { libc::mkfifo(name.as_ptr(), 0o644) };
        assert_eq!(made, 0, "mkfifo {path:?}");
    }

    /// The FIFO's write end, if a read of it has started.
    fn writer(path: &Path) -> Option<File> {
        OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(path)
            .ok()
    }

    /// The FIFO's write end once a read of it starts; held, the read
    /// waits for bytes.
    async fn read_started(path: &Path) -> File {
        with_deadline("a read of the fifo", async {
            loop {
                if let Some(writer) = writer(path) {
                    return writer;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
    }

    /// A review of `held.txt` and `new.txt`, both copies from A; `held.txt`
    /// already a FIFO. The session, the plan under review and both rows.
    async fn reviewing(head: &mut Head) -> (u64, u64, u32, u32) {
        write(&head.path("a/held.txt"), "held\n");
        write(&head.path("a/new.txt"), "hello\n");
        std::fs::create_dir_all(head.path("b")).unwrap_or_else(|error| panic!("{error}"));
        local_profile(head, "local", "a", "b");
        let (session, _) = head.ok(start("local", false, None, GUARD)).await;
        let view = review(head, session).await;
        fifo(&head.path("a/held.txt"));
        let plan = plan_id(&view);
        (session, plan, row(&view, "held.txt"), row(&view, "new.txt"))
    }

    #[tokio::test]
    async fn confirm_during_a_compare_applies_at_once_and_fails_the_compare() {
        let mut head = Head::new("studio").await;
        let (session, plan, held, _) = reviewing(&mut head).await;
        let skip = RunIntent::ChooseAction {
            plan_id: plan,
            index: held,
            choice: hub::views::ActionChoiceView::Skipped,
        };
        head.ok(steer(session, skip)).await;
        let id = head.fresh_id();
        let comparing = head.spawn(id, compare(session, plan, action(held)));
        let writer = read_started(&head.path("a/held.txt")).await;

        head.ok(steer(session, RunIntent::Confirm { plan_id: plan }))
            .await;
        let reply = comparing.await;
        assert_eq!(
            failure(reply.unwrap_or_else(|e| panic!("{e}"))),
            REVIEW_CLOSED
        );
        let views = head.run_until(session, ended).await;
        assert!(views.last().is_some_and(is("finished")));
        assert_eq!(read(&head.path("b/new.txt")), "hello\n");
        drop(writer);
    }

    #[tokio::test]
    async fn a_cancelled_compare_fails_and_the_review_stays_open() {
        let mut head = Head::new("studio").await;
        let (session, plan, held, new) = reviewing(&mut head).await;
        let id = head.fresh_id();
        let comparing = head.spawn(id, compare(session, plan, action(held)));
        let writer = read_started(&head.path("a/held.txt")).await;

        let cancel = CoreCommand::CancelCompare {
            session,
            request: id,
        };
        assert!(matches!(head.ok(cancel).await.1, ReplyResult::Done));
        let reply = comparing.await;
        assert_eq!(failure(reply.unwrap_or_else(|e| panic!("{e}"))), CANCELLED);
        drop(writer);

        // Still under review: the next compare is served.
        let (_, _, _, verdict) = compared(head.ok(compare(session, plan, action(new))).await.1);
        assert_eq!(blocks(&verdict), [(1, 1, vec!["+hello".to_owned()])]);
        head.ok(steer(session, RunIntent::Stop)).await;
        head.run_until(session, ended).await;
    }

    #[tokio::test]
    async fn a_cancel_handled_before_its_compare_fails_it_unread() {
        let mut head = Head::new("studio").await;
        let (session, plan, held, _) = reviewing(&mut head).await;
        let id = head.fresh_id();
        let cancel = CoreCommand::CancelCompare {
            session,
            request: id,
        };
        head.ok(cancel).await;
        let reply = head.spawn(id, compare(session, plan, action(held))).await;
        // Probed before any assert: a read found here is released at once,
        // so a failing run fails rather than hangs on the waiting open.
        let read = writer(&head.path("a/held.txt")).is_some();
        assert!(!read, "nothing read");
        assert_eq!(failure(reply.unwrap_or_else(|e| panic!("{e}"))), CANCELLED);

        // The same probe sees a compare that does read it.
        let id = head.fresh_id();
        let comparing = head.spawn(id, compare(session, plan, action(held)));
        let mut writer = read_started(&head.path("a/held.txt")).await;
        writer
            .write_all(b"late\n")
            .unwrap_or_else(|error| panic!("{error}"));
        drop(writer);
        let reply = comparing.await;
        let (_, _, _, verdict) = compared(reply.unwrap_or_else(|e| panic!("{e}")));
        assert_eq!(blocks(&verdict), [(1, 1, vec!["+late".to_owned()])]);
        head.ok(steer(session, RunIntent::Stop)).await;
        head.run_until(session, ended).await;
    }

    #[tokio::test]
    async fn a_pause_during_the_review_fails_the_pending_compare() {
        let mut head = Head::new("studio").await;
        let (session, plan, held, new) = reviewing(&mut head).await;
        let id = head.fresh_id();
        let comparing = head.spawn(id, compare(session, plan, action(held)));
        let writer = read_started(&head.path("a/held.txt")).await;

        head.ok(steer(session, RunIntent::Pause)).await;
        let reply = comparing.await;
        assert_eq!(
            failure(reply.unwrap_or_else(|e| panic!("{e}"))),
            REVIEW_CLOSED
        );
        drop(writer);
        head.run_until(session, is("paused")).await;
        assert_eq!(
            failure(head.ask(compare(session, plan, action(new))).await.1),
            REVIEW_CLOSED
        );
        head.ok(steer(session, RunIntent::Close)).await;
    }
}
