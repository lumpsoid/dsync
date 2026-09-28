//! The cases of `test/dsync_core/archive/jsonl_archive_store_test.dart`,
//! plus the repairs and refusals the Rust store adds.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use dsync_core::{ARCHIVE_FORMAT_VERSION, ArchiveError, ArchiveHeader, ArchiveStore};
use dsync_domain::{Archive, ArchiveCommit, FormatVersion, Tuning};
use tempfile::TempDir;

use crate::stores::support::{file, names_in, path, profile, upsert};

struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn log(&self) -> PathBuf {
        self.dir.path().join("archive.jsonl")
    }

    fn header() -> ArchiveHeader {
        ArchiveHeader {
            entry_id: profile(),
            root_path: "/home/me/notes".into(),
        }
    }

    fn open(&self) -> ArchiveStore {
        self.open_with(&Tuning::DEFAULT)
    }

    fn open_with(&self, tuning: &Tuning) -> ArchiveStore {
        ArchiveStore::open(self.log(), Fixture::header(), tuning).unwrap()
    }

    /// The archive a fresh store replays from disk.
    fn reloaded(&self) -> Archive {
        self.open().archive().clone()
    }

    fn lines(&self) -> Vec<String> {
        fs::read_to_string(self.log())
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Commit lines on disk, less the header; 0 with no log.
    fn commit_lines(&self) -> usize {
        if !self.log().exists() {
            return 0;
        }
        self.lines().len().saturating_sub(1)
    }

    fn append_raw(&self, bytes: &str) {
        OpenOptions::new()
            .append(true)
            .open(self.log())
            .unwrap()
            .write_all(bytes.as_bytes())
            .unwrap();
    }

    /// A fragment of a record, as a crash partway through an append leaves.
    fn tear(&self) {
        self.append_raw(r#"{"op":"upsert","path":"b.t"#);
    }
}

fn entry() -> ArchiveCommit {
    upsert("a.txt", file(10, 1))
}

fn at(name: &str) -> ArchiveCommit {
    upsert(name, file(1, 2))
}

fn committed(store: &mut ArchiveStore, batch: impl IntoIterator<Item = ArchiveCommit>) {
    store.commit(batch).unwrap();
}

fn marked(archive: &Archive) -> Vec<&str> {
    archive.untrusted().map(|path| path.as_str()).collect()
}

fn names(archive: &Archive) -> Vec<&str> {
    archive.entries().map(|(path, _)| path.as_str()).collect()
}

// --- load ---

#[test]
fn a_missing_log_opens_an_empty_archive_with_the_given_header() {
    let fixture = Fixture::new();
    let store = fixture.open();
    assert_eq!(store.header(), &Fixture::header());
    assert!(store.archive().is_empty());
}

#[test]
fn replays_a_committed_upsert() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    store.flush().unwrap();

    assert_eq!(fixture.reloaded().get(&path("a.txt")), Some(&file(10, 1)));
}

#[test]
fn a_tombstone_after_an_upsert_removes_the_path() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry(), ArchiveCommit::Delete(path("a.txt"))]);
    store.flush().unwrap();

    assert!(fixture.reloaded().is_empty());
}

#[test]
fn last_write_per_path_wins_on_replay() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [entry(), at("b.txt"), upsert("a.txt", file(99, 3))],
    );
    store.flush().unwrap();

    let archive = fixture.reloaded();
    assert_eq!(archive.get(&path("a.txt")), Some(&file(99, 3)));
    assert_eq!(archive.len(), 2);
}

#[test]
fn a_path_deleted_then_recreated_is_present_after_replay() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [
            entry(),
            ArchiveCommit::Delete(path("a.txt")),
            upsert("a.txt", file(11, 4)),
        ],
    );
    store.flush().unwrap();

    assert_eq!(fixture.reloaded().get(&path("a.txt")), Some(&file(11, 4)));
}

// --- header ---

#[test]
fn the_header_is_written_once_not_once_per_commit() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    committed(&mut store, [ArchiveCommit::Delete(path("a.txt"))]);
    committed(&mut store, [entry()]);
    store.flush().unwrap();

    let lines = fixture.lines();
    assert_eq!(
        lines
            .iter()
            .filter(|l| l.contains(r#""op":"header""#))
            .count(),
        1
    );
    assert_eq!(lines.len(), 4);
}

#[test]
fn a_commit_against_an_existing_log_does_not_add_a_second_header() {
    let fixture = Fixture::new();
    let mut writer = fixture.open();
    committed(&mut writer, [entry()]);
    writer.flush().unwrap();
    drop(writer);

    let mut reopened = fixture.open();
    committed(&mut reopened, [ArchiveCommit::Delete(path("a.txt"))]);
    reopened.flush().unwrap();

    let headers = fixture
        .lines()
        .iter()
        .filter(|l| l.contains(r#""op":"header""#))
        .count();
    assert_eq!(headers, 1);
    assert_eq!(fixture.commit_lines(), 2);
}

#[test]
fn the_first_line_of_a_new_log_is_the_header() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    store.flush().unwrap();

    let first = &fixture.lines()[0];
    assert!(first.contains(r#""op":"header""#), "{first}");
    assert!(first.contains(&format!(r#""version":"{ARCHIVE_FORMAT_VERSION}""#)));
    assert_eq!(ARCHIVE_FORMAT_VERSION.to_string(), "1.0");
    assert!(first.contains(&format!(r#""entry_id":"{}""#, profile().as_str())));
    assert!(first.contains(r#""rootPath":"/home/me/notes""#));
}

#[test]
fn a_store_that_commits_nothing_leaves_no_file_behind() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    store.flush().unwrap();
    store.compact().unwrap();
    drop(store);

    assert!(!fixture.log().exists());
}

fn open_err(fixture: &Fixture, header: ArchiveHeader) -> ArchiveError {
    ArchiveStore::open(fixture.log(), header, &Tuning::DEFAULT).unwrap_err()
}

#[test]
fn refuses_a_log_written_for_a_different_root_or_profile() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    drop(store);

    let moved = ArchiveHeader {
        root_path: "/home/me/elsewhere".into(),
        ..Fixture::header()
    };
    let error = open_err(&fixture, moved);
    assert!(matches!(error, ArchiveError::Mismatch { .. }), "{error:?}");
    assert!(error.to_string().contains("/home/me/elsewhere"), "{error}");

    let other = ArchiveHeader {
        entry_id: dsync_domain::EntryId::parse(&"f".repeat(32)).unwrap(),
        ..Fixture::header()
    };
    assert!(matches!(
        open_err(&fixture, other),
        ArchiveError::Mismatch { .. }
    ));

    // Positive control: the right header opens it.
    assert_eq!(fixture.reloaded().len(), 1);
}

/// A log whose header names `version`, over this very profile and root,
/// with one upsert after it.
fn write_log_of_version(fixture: &Fixture, version: &str) {
    fs::write(
        fixture.log(),
        format!(
            "{{\"op\":\"header\",\"version\":\"{version}\",\"entry_id\":\"{}\",\
             \"rootPath\":\"/home/me/notes\"}}\n\
             {{\"op\":\"upsert\",\"path\":\"a.txt\",\"size\":10,\"mtime\":123456,\
             \"mode\":420,\"hash\":\"deadbeef\"}}\n",
            profile().as_str()
        ),
    )
    .unwrap();
}

#[test]
fn refuses_a_log_of_another_major_naming_both_versions_and_the_file() {
    let fixture = Fixture::new();
    for (version, found) in [
        ("2.0", FormatVersion::new(2, 0)),
        ("0.3", FormatVersion::new(0, 3)),
    ] {
        write_log_of_version(&fixture, version);
        let error = open_err(&fixture, Fixture::header());
        let message = error.to_string();
        match error {
            ArchiveError::ForeignVersion {
                path,
                found: actual,
            } => {
                assert_eq!(path, fixture.log());
                assert_eq!(actual, found);
            }
            other => panic!("expected a foreign-version refusal, got {other:?}"),
        }
        assert!(
            message.contains(&format!("is format {version}")),
            "{message}"
        );
        assert!(message.contains("(format 1.0)"), "{message}");
        let log = fixture.log().display().to_string();
        assert!(message.contains(&format!("delete {log}")), "{message}");
    }
}

/// A later minor may add fields to any line; this build replays the log
/// as if they were not there.
#[test]
fn reads_a_later_minor_whose_lines_carry_fields_it_does_not_know() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    drop(store);
    let expected = fixture.reloaded();

    let text = fs::read_to_string(fixture.log())
        .unwrap()
        .replace(
            r#""version":"1.0""#,
            r#""version":"1.4","createdBy":"later""#,
        )
        .replace(r#""op":"upsert""#, r#""op":"upsert","xattrs":{"k":"v"}"#);
    assert!(text.contains("1.4") && text.contains("xattrs"), "{text}");
    fs::write(fixture.log(), text).unwrap();

    assert_eq!(fixture.reloaded(), expected);
}

#[test]
fn a_first_line_that_is_not_a_header_is_corruption_at_that_line() {
    let fixture = Fixture::new();
    fs::write(
        fixture.log(),
        "{\"op\":\"upsert\",\"path\":\"a.txt\",\"size\":1,\"mtime\":1,\"mode\":420,\"hash\":\"h\"}\n",
    )
    .unwrap();

    let error = open_err(&fixture, Fixture::header());
    assert!(
        matches!(&error, ArchiveError::Corrupt { line: 1, .. }),
        "{error:?}"
    );
    assert!(error.to_string().contains("not a header"), "{error}");
}

// --- torn tail ---

#[test]
fn a_half_written_last_line_is_dropped_and_earlier_lines_survive() {
    let fixture = Fixture::new();
    let mut writer = fixture.open();
    committed(&mut writer, [entry()]);
    writer.flush().unwrap();
    fixture.tear();

    let archive = fixture.reloaded();
    assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));
    assert_eq!(archive.get(&path("b.txt")), None);
}

#[test]
fn the_torn_bytes_are_removed_before_the_next_commit() {
    let fixture = Fixture::new();
    let mut writer = fixture.open();
    committed(&mut writer, [entry()]);
    writer.flush().unwrap();
    drop(writer);
    fixture.tear();

    let mut reopened = fixture.open();
    committed(&mut reopened, [ArchiveCommit::Delete(path("a.txt"))]);
    reopened.flush().unwrap();
    drop(reopened);

    // Appending onto the fragment would have spliced it into the next
    // record: corruption mid-log, which the next open refuses.
    assert!(fixture.reloaded().is_empty());
    assert!(!fs::read_to_string(fixture.log()).unwrap().contains("b.t"));
}

#[test]
fn a_whole_last_line_missing_its_newline_is_repaired_before_appending() {
    let fixture = Fixture::new();
    let mut writer = fixture.open();
    committed(&mut writer, [entry()]);
    writer.flush().unwrap();
    drop(writer);
    let intact = fs::read_to_string(fixture.log()).unwrap();
    fs::write(fixture.log(), intact.trim_end_matches('\n')).unwrap();

    let mut reopened = fixture.open();
    assert_eq!(
        reopened.archive().len(),
        1,
        "the unterminated line is whole"
    );
    committed(&mut reopened, [at("b.txt")]);
    reopened.flush().unwrap();
    drop(reopened);

    assert_eq!(names(&fixture.reloaded()), ["a.txt", "b.txt"]);
}

#[test]
fn a_first_write_cut_short_inside_the_header_opens_empty_and_is_repaired() {
    let fixture = Fixture::new();
    fs::write(fixture.log(), r#"{"op":"header","schemaVer"#).unwrap();

    let mut store = fixture.open();
    assert!(store.archive().is_empty());
    committed(&mut store, [entry()]);
    store.flush().unwrap();
    drop(store);

    assert_eq!(names(&fixture.reloaded()), ["a.txt"]);
    assert!(fixture.lines()[0].contains(r#""op":"header""#));
}

fn corrupt_after_one_commit(fixture: &Fixture) {
    let mut writer = fixture.open();
    committed(&mut writer, [entry()]);
    writer.flush().unwrap();
    drop(writer);
    fixture.append_raw("not json\n{\"op\":\"delete\",\"path\":\"a.txt\"}\n");
}

#[test]
fn corruption_before_a_torn_tail_still_aborts_the_open() {
    // Only the final line is forgivable: a reader that called the first
    // bad line the tail would lose this corruption silently.
    let fixture = Fixture::new();
    corrupt_after_one_commit(&fixture);
    fixture.tear();

    let error = open_err(&fixture, Fixture::header());
    assert!(
        matches!(error, ArchiveError::Corrupt { line: 3, .. }),
        "{error:?}"
    );
}

#[test]
fn a_malformed_line_that_is_not_the_last_aborts_the_open() {
    let fixture = Fixture::new();
    corrupt_after_one_commit(&fixture);

    let error = open_err(&fixture, Fixture::header());
    assert!(
        matches!(error, ArchiveError::Corrupt { line: 3, .. }),
        "{error:?}"
    );
}

#[test]
fn a_last_line_of_the_wrong_shape_is_corruption_not_a_tear() {
    let fixture = Fixture::new();
    let mut writer = fixture.open();
    committed(&mut writer, [entry()]);
    writer.flush().unwrap();
    drop(writer);
    fixture.append_raw("{\"op\":\"upsert\",\"path\":\"../escape\"}\n");

    let error = open_err(&fixture, Fixture::header());
    assert!(
        matches!(error, ArchiveError::Corrupt { line: 3, .. }),
        "{error:?}"
    );
}

// --- snapshot ---

#[test]
fn a_cloned_archive_does_not_shift_under_later_commits() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    let loaded = store.archive().clone();

    committed(&mut store, [entry()]);
    store.flush().unwrap();

    assert!(loaded.is_empty());
    assert_eq!(store.archive().len(), 1);
}

#[test]
fn reflects_commits_made_since_open_without_rereading_the_file() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    store.flush().unwrap();
    fs::remove_file(fixture.log()).unwrap();

    assert_eq!(store.archive().get(&path("a.txt")), Some(&file(10, 1)));
}

// --- last commit ---

#[test]
fn last_commit_is_none_when_no_log_exists() {
    let fixture = Fixture::new();
    assert_eq!(fixture.open().last_commit().unwrap(), None);
}

#[test]
fn last_commit_is_the_log_mtime_once_a_commit_has_happened() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    store.flush().unwrap();

    let expected = fs::metadata(fixture.log()).unwrap().modified().unwrap();
    assert_eq!(store.last_commit().unwrap(), Some(expected));
}

#[test]
fn last_commit_answers_about_every_commit_made() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    assert_eq!(store.last_commit().unwrap(), None);

    committed(&mut store, [entry()]);

    assert!(store.last_commit().unwrap().is_some());
}

// --- batching ---

#[test]
fn a_commit_is_visible_to_this_store_before_it_reaches_disk() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);

    assert_eq!(store.archive().get(&path("a.txt")), Some(&file(10, 1)));
    assert!(!fixture.log().exists());
}

#[test]
fn a_batch_of_commits_costs_one_append_not_one_per_commit() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    for i in 0..20 {
        committed(&mut store, [at(&format!("f{i}"))]);
    }
    assert_eq!(fixture.commit_lines(), 0, "still buffered");

    store.flush().unwrap();

    assert_eq!(fixture.commit_lines(), 20);
    let reloaded = fixture.reloaded();
    assert_eq!(reloaded.len(), 20);
    assert_eq!(reloaded.get(&path("f19")), Some(&file(1, 2)));
}

#[test]
fn the_buffer_is_written_once_it_holds_the_batch_line_count() {
    let fixture = Fixture::new();
    let three = Tuning {
        archive_buffer_lines: 3,
        ..Tuning::DEFAULT
    };
    let mut store = fixture.open_with(&three);
    committed(&mut store, [at("f0")]);
    committed(&mut store, [at("f1")]);
    assert_eq!(fixture.commit_lines(), 0, "below the line count");

    committed(&mut store, [at("f2")]);
    assert_eq!(fixture.commit_lines(), 3);
}

#[test]
fn the_buffer_is_written_once_its_oldest_commit_is_old_enough() {
    let fixture = Fixture::new();
    let at_once = Tuning {
        archive_buffer_interval: Duration::ZERO,
        ..Tuning::DEFAULT
    };
    let mut store = fixture.open_with(&at_once);
    committed(&mut store, [at("f0")]);
    assert_eq!(fixture.commit_lines(), 1);

    // Control: the shipped interval holds the same commit back.
    let other = Fixture::new();
    let mut store = other.open();
    committed(&mut store, [at("f0")]);
    assert_eq!(other.commit_lines(), 0);
}

#[test]
fn an_intent_is_on_disk_before_the_commit_recording_it_returns() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [at("f0")]);
    assert_eq!(fixture.commit_lines(), 0, "an ordinary commit is buffered");

    committed(&mut store, [at("f1"), ArchiveCommit::Intent(path("f2"))]);

    assert_eq!(fixture.commit_lines(), 3);
    assert_eq!(marked(&fixture.reloaded()), ["f2"]);
}

#[test]
fn flushing_nothing_writes_nothing() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    store.flush().unwrap();
    assert!(!fixture.log().exists());
}

#[test]
fn dropping_the_store_writes_the_buffer_out() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    drop(store);

    assert_eq!(fixture.commit_lines(), 1);
    assert_eq!(fixture.reloaded().len(), 1);
}

#[test]
fn compact_carries_commits_that_never_reached_the_log() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);

    store.compact().unwrap();

    // Read while the store is still open, so nothing on drop helps.
    assert_eq!(fixture.reloaded().get(&path("a.txt")), Some(&file(10, 1)));
    drop(store);
}

#[test]
fn a_batch_is_torn_never_interleaved_by_a_crash_mid_append() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry(), at("b.txt")]);
    store.flush().unwrap();
    drop(store);

    let intact = fs::read_to_string(fixture.log()).unwrap();
    fs::write(fixture.log(), &intact[..intact.len() - 8]).unwrap();

    let mut reopened = fixture.open();
    assert_eq!(names(reopened.archive()), ["a.txt"]);

    committed(&mut reopened, [at("c.txt")]);
    reopened.flush().unwrap();
    drop(reopened);
    assert_eq!(names(&fixture.reloaded()), ["a.txt", "c.txt"]);
}

/// A failed append must not drop the commits it was carrying: `archive`
/// already holds them, and the next flush has to get them onto disk by
/// rewriting the whole log rather than by resuming the append.
#[cfg(unix)]
#[test]
fn a_failed_append_is_recovered_by_a_rewrite_on_the_next_flush() {
    use std::os::unix::fs::PermissionsExt;

    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    store.flush().unwrap(); // The log exists, so appending to it can be blocked.

    fs::set_permissions(fixture.log(), fs::Permissions::from_mode(0o444)).unwrap();
    if OpenOptions::new().append(true).open(fixture.log()).is_ok() {
        // Running as root: permissions do not bind, so there is nothing to
        // provoke. Say so rather than pass vacuously.
        fs::set_permissions(fixture.log(), fs::Permissions::from_mode(0o644)).unwrap();
        eprintln!("skipped: file permissions do not bind for this user");
        return;
    }

    committed(&mut store, [at("b.txt")]);
    let result = store.flush();
    assert!(matches!(result, Err(ArchiveError::Io { .. })), "{result:?}");

    // The directory stays writable throughout: the recovery rewrite goes
    // through `write_atomically`, which only needs to create a temp file
    // and rename it in place.
    fs::set_permissions(fixture.log(), fs::Permissions::from_mode(0o644)).unwrap();
    store.flush().unwrap();
    drop(store);

    assert_eq!(names(&fixture.reloaded()), ["a.txt", "b.txt"]);
}

// --- compact ---

fn updated() -> ArchiveCommit {
    upsert("a.txt", file(99, 9))
}

#[test]
fn compact_rewrites_the_log_to_one_line_per_live_path() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [
            entry(),
            updated(),
            at("b.txt"),
            ArchiveCommit::Delete(path("b.txt")),
        ],
    );

    store.compact().unwrap();

    // The header plus one upsert per live path.
    assert_eq!(fixture.lines().len(), 2);
    let archive = fixture.reloaded();
    assert_eq!(archive.get(&path("a.txt")), Some(&file(99, 9)));
    assert_eq!(archive.get(&path("b.txt")), None);
    assert_eq!(
        names_in(fixture.dir.path()),
        ["archive.jsonl"],
        "no temp left"
    );
}

#[test]
fn compact_is_a_no_op_when_the_log_already_holds_one_line_per_path() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry()]);
    store.flush().unwrap();
    let before = fs::read_to_string(fixture.log()).unwrap();
    let mtime = fs::metadata(fixture.log()).unwrap().modified().unwrap();

    store.compact().unwrap();

    assert_eq!(fs::read_to_string(fixture.log()).unwrap(), before);
    assert_eq!(
        fs::metadata(fixture.log()).unwrap().modified().unwrap(),
        mtime
    );
    assert_eq!(names_in(fixture.dir.path()), ["archive.jsonl"]);
}

/// A compaction that cannot swap its rewrite in - here, a directory it
/// may not write - fails and leaves the old log exactly as it was. The
/// kill between the temp write and the rename is in `atomic_write.rs`.
#[cfg(unix)]
#[test]
fn a_compaction_that_cannot_swap_in_leaves_the_old_log_intact() {
    use std::os::unix::fs::PermissionsExt;

    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry(), updated()]);
    store.flush().unwrap(); // Two lines on disk, one live entry.
    let before = fs::read_to_string(fixture.log()).unwrap();

    let dir = fixture.dir.path();
    fs::set_permissions(dir, fs::Permissions::from_mode(0o555)).unwrap();
    if fs::write(dir.join("probe"), "").is_ok() {
        // Running as root: permissions do not bind, so there is nothing to
        // provoke. Say so rather than pass vacuously.
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).unwrap();
        eprintln!("skipped: directory permissions do not bind for this user");
        return;
    }
    let result = store.compact();
    fs::set_permissions(dir, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(matches!(result, Err(ArchiveError::Io { .. })), "{result:?}");
    assert_eq!(fs::read_to_string(fixture.log()).unwrap(), before);
    // And a later compaction, allowed, goes through.
    store.compact().unwrap();
    assert_eq!(fixture.lines().len(), 2);
}

// --- intents (SPEC §7.6) ---

#[test]
fn an_intent_marks_a_path_without_touching_its_entry_and_survives_a_reopen() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [
            entry(),
            ArchiveCommit::Intent(path("a.txt")),
            ArchiveCommit::Intent(path("new.txt")),
        ],
    );

    let archive = fixture.reloaded();
    assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));
    assert_eq!(archive.get(&path("new.txt")), None);
    assert_eq!(marked(&archive), ["a.txt", "new.txt"]);
}

#[test]
fn an_upsert_or_tombstone_after_an_intent_clears_it_one_before_does_not() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [
            ArchiveCommit::Intent(path("a.txt")),
            ArchiveCommit::Intent(path("b.txt")),
            ArchiveCommit::Intent(path("c.txt")),
        ],
    );
    committed(&mut store, [entry(), ArchiveCommit::Delete(path("b.txt"))]);
    store.flush().unwrap();

    assert_eq!(marked(store.archive()), ["c.txt"]);
    assert_eq!(marked(&fixture.reloaded()), ["c.txt"]);
}

#[test]
fn a_withdrawal_clears_it_and_leaves_the_entry_across_a_reopen_and_a_compaction() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [
            entry(),
            ArchiveCommit::Intent(path("a.txt")),
            ArchiveCommit::Intent(path("new.txt")),
        ],
    );
    committed(
        &mut store,
        [
            ArchiveCommit::Withdraw(path("a.txt")),
            ArchiveCommit::Withdraw(path("new.txt")),
        ],
    );
    store.flush().unwrap();

    assert!(marked(store.archive()).is_empty());
    let archive = fixture.reloaded();
    assert!(marked(&archive).is_empty());
    assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));
    assert_eq!(archive.get(&path("new.txt")), None);

    store.compact().unwrap();
    // The header and the one live entry: nothing of the marks is left.
    assert_eq!(fixture.lines().len(), 2);
}

#[test]
fn compaction_carries_an_open_intent_forward_after_the_entry_it_qualifies() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(
        &mut store,
        [entry(), entry(), ArchiveCommit::Intent(path("a.txt"))],
    );

    store.compact().unwrap();

    // The header, the one live entry, the one open intent.
    assert_eq!(fixture.lines().len(), 3);
    let archive = fixture.reloaded();
    assert_eq!(archive.get(&path("a.txt")), Some(&file(10, 1)));
    assert_eq!(marked(&archive), ["a.txt"]);
}

#[test]
fn a_log_already_one_line_per_entry_and_intent_is_not_rewritten() {
    let fixture = Fixture::new();
    let mut store = fixture.open();
    committed(&mut store, [entry(), ArchiveCommit::Intent(path("a.txt"))]);
    drop(store);
    let before = fs::read_to_string(fixture.log()).unwrap();
    let mtime = fs::metadata(fixture.log()).unwrap().modified().unwrap();

    let mut reopened = fixture.open();
    reopened.compact().unwrap();

    assert_eq!(fs::read_to_string(fixture.log()).unwrap(), before);
    assert_eq!(
        fs::metadata(fixture.log()).unwrap().modified().unwrap(),
        mtime
    );
}
