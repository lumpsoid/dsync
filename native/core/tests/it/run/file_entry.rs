//! A single-file entry through a run (plan D8), side B local and served:
//! the file syncs both ways under each side's own name, deletes both
//! ways, never offers keeping both, is never read as deleted when it
//! cannot be read, ignores the profile's rules, and is skipped - nothing
//! locked, nothing written - when its folder is missing or a folder
//! stands in its place.

use std::fs;
use std::path::PathBuf;

use dsync_core::{
    BatchDecider, Connector, EntryOutcome, LocalReplica, ProfileEvent, ProfileRun, ProfileStop,
    RemoteReplica, RunError, RunEvent, SkipReason, StateDir,
};
use dsync_domain::{
    EffectiveOptions, Flags, HostFacts, Platform, Profile, ProfileName, ReplicaSpec, Resolution,
    RootKind, RunFlags, Side, SkippedReason, Tuning,
};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::run::support::{Finished, Site, run_with, serve, with_deadline};

#[derive(Clone, Copy, Debug)]
enum Reach {
    Local,
    Served,
}

/// A file entry between `a/notes.md` and `b/other.md` of a [`Site`], or
/// wherever its fields put the two files.
struct FileEntry {
    site: Site,
    a: PathBuf,
    b: PathBuf,
    ignore: &'static str,
}

impl FileEntry {
    fn new() -> FileEntry {
        let site = Site::new();
        FileEntry {
            a: site.file(Side::A, "notes.md"),
            b: site.file(Side::B, "other.md"),
            site,
            ignore: "",
        }
    }

    fn file(&self, side: Side) -> &PathBuf {
        match side {
            Side::A => &self.a,
            Side::B => &self.b,
        }
    }

    fn put(&self, side: Side, content: &str) {
        fs::write(self.file(side), content).unwrap();
    }

    fn get(&self, side: Side) -> Option<String> {
        fs::read_to_string(self.file(side)).ok()
    }

    fn profile(&self) -> Profile {
        let text = format!(
            "[[entries]]\nkind = \"file\"\na = '{}'\nb = '{}'\n[rules]\nignore = [{}]\n",
            self.a.display(),
            self.b.display(),
            self.ignore
        );
        Profile::parse(&text, Platform::HOST).unwrap()
    }

    fn options(&self) -> EffectiveOptions {
        let mut options = self
            .profile()
            .options(
                &ProfileName::parse("p").unwrap(),
                &RunFlags::validate(dsync_domain::Command::Sync, Flags::default()).unwrap(),
                &HostFacts::new(Platform::HOST, None, [], "/".to_owned()),
            )
            .unwrap();
        assert_eq!(options.len(), 1);
        options.remove(0)
    }

    fn spec(&self, side: Side) -> ReplicaSpec {
        let options = self.options();
        ReplicaSpec {
            root: self.file(side).to_str().unwrap().to_owned(),
            kind: RootKind::File,
            as_path: options.as_path().cloned(),
            entry: options.entry_id,
            side,
            jobs: dsync_domain::Jobs::DEFAULT,
        }
    }

    fn replica(&self, side: Side) -> LocalReplica {
        let spec = self.spec(side);
        LocalReplica::open(
            dsync_core::Root::new(spec.root, spec.kind, spec.as_path).unwrap(),
            self.site.state(),
            spec.entry,
            side,
            spec.jobs,
            Tuning::DEFAULT,
            dsync_core::Symlinks::AsRuled,
        )
    }

    async fn served(
        &self,
        side: Side,
    ) -> (RemoteReplica, JoinHandle<Result<(), dsync_core::LinkError>>) {
        let (near, far) = tokio::io::duplex(64 * 1024);
        let serving = serve(&self.site, far);
        let replica = with_deadline(
            "connect",
            RemoteReplica::connect(
                dsync_core::Transport::split(near),
                self.spec(side),
                &Tuning::DEFAULT,
            ),
        )
        .await
        .unwrap();
        (replica, serving)
    }

    /// A batch run, side B reached as `reach`.
    async fn sync(&self, reach: Reach) -> Finished {
        let options = self.options();
        let a = self.replica(Side::A);
        match reach {
            Reach::Local => {
                run_with(
                    &self.site,
                    a,
                    self.replica(Side::B),
                    &options,
                    &mut BatchDecider,
                    Tuning::DEFAULT,
                )
                .await
            }
            Reach::Served => {
                let (b, serving) = self.served(Side::B).await;
                let finished = run_with(
                    &self.site,
                    a,
                    b,
                    &options,
                    &mut BatchDecider,
                    Tuning::DEFAULT,
                )
                .await;
                with_deadline("the session's end", serving)
                    .await
                    .unwrap()
                    .unwrap();
                finished
            }
        }
    }

    /// Lock files in the state dir: a run's, or the folder's.
    fn locks(&self) -> Vec<String> {
        let state = self.site.root(Side::A).parent().unwrap().join("state");
        let Ok(entries) = fs::read_dir(state) else {
            return Vec::new();
        };
        entries
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name.ends_with(".lock"))
            .collect()
    }
}

/// `side`'s folder, name by name.
fn listing(entry: &FileEntry, side: Side) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(entry.site.root(side))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

fn synced(finished: &Finished, reach: Reach) {
    assert_eq!(
        finished.exit_code(),
        0,
        "{reach:?}: {:?}",
        finished.errors()
    );
}

async fn syncs_both_ways(reach: Reach) {
    let entry = FileEntry::new();
    entry.put(Side::A, "one");
    entry.site.put(Side::A, "sibling.txt", "not synced");

    synced(&entry.sync(reach).await, reach);
    assert_eq!(entry.get(Side::B).as_deref(), Some("one"), "{reach:?}");
    // Nothing but the file crossed, and no probe was left beside it.
    assert_eq!(listing(&entry, Side::B), ["other.md"], "{reach:?}");
    assert_eq!(
        listing(&entry, Side::A),
        ["notes.md", "sibling.txt"],
        "{reach:?}"
    );

    entry.put(Side::B, "two, edited");
    synced(&entry.sync(reach).await, reach);
    assert_eq!(
        entry.get(Side::A).as_deref(),
        Some("two, edited"),
        "{reach:?}"
    );

    fs::remove_file(&entry.a).unwrap();
    synced(&entry.sync(reach).await, reach);
    assert_eq!(entry.get(Side::B), None, "{reach:?}");
    assert!(entry.site.root(Side::B).is_dir(), "{reach:?}");

    entry.put(Side::B, "back");
    synced(&entry.sync(reach).await, reach);
    assert_eq!(entry.get(Side::A).as_deref(), Some("back"), "{reach:?}");

    fs::remove_file(&entry.b).unwrap();
    synced(&entry.sync(reach).await, reach);
    assert_eq!(entry.get(Side::A), None, "{reach:?}");
    assert_eq!(listing(&entry, Side::A), ["sibling.txt"], "{reach:?}");
    assert!(listing(&entry, Side::B).is_empty(), "{reach:?}");
}

#[tokio::test]
async fn a_file_syncs_both_ways_under_each_sides_own_name_edits_and_deletes_included() {
    for reach in [Reach::Local, Reach::Served] {
        syncs_both_ways(reach).await;
    }
}

#[tokio::test]
async fn a_conflict_in_a_file_entry_offers_keeping_one_side_only() {
    for reach in [Reach::Local, Reach::Served] {
        let entry = FileEntry::new();
        entry.put(Side::A, "same");
        synced(&entry.sync(reach).await, reach);
        entry.put(Side::A, "edited on a");
        entry.put(Side::B, "edited on b, longer");

        let finished = entry.sync(reach).await;

        let conflicts: Vec<_> = finished
            .events
            .iter()
            .filter_map(|event| match event {
                RunEvent::Conflict(conflict) => Some(conflict),
                _ => None,
            })
            .collect();
        let [conflict] = conflicts[..] else {
            panic!("{reach:?}: {conflicts:?}");
        };
        assert_eq!(conflict.path.as_str(), "notes.md");
        assert_eq!(
            conflict.offers(),
            [Resolution::Keep(Side::A), Resolution::Keep(Side::B)],
            "{reach:?}"
        );
        assert_eq!(entry.get(Side::A).as_deref(), Some("edited on a"));
        assert_eq!(entry.get(Side::B).as_deref(), Some("edited on b, longer"));
    }
}

#[cfg(unix)]
#[tokio::test]
async fn an_unreadable_file_is_reported_and_not_deleted_on_the_other_side() {
    use std::os::unix::fs::PermissionsExt;

    for reach in [Reach::Local, Reach::Served] {
        let entry = FileEntry::new();
        entry.put(Side::A, "one");
        synced(&entry.sync(reach).await, reach);
        // Changed since, so the scan must read it: an unchanged size and
        // mtime would settle it without a read.
        entry.put(Side::A, "one, edited since");
        fs::set_permissions(&entry.a, fs::Permissions::from_mode(0o000)).unwrap();
        // Root reads anything: the permission is not binding there.
        if fs::File::open(&entry.a).is_ok() {
            fs::set_permissions(&entry.a, fs::Permissions::from_mode(0o644)).unwrap();
            return;
        }

        let finished = entry.sync(reach).await;

        fs::set_permissions(&entry.a, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(entry.get(Side::B).as_deref(), Some("one"), "{reach:?}");
        let skipped: Vec<_> = finished
            .events
            .iter()
            .filter_map(|event| match event {
                RunEvent::Skipped { side, skipped } => Some((*side, skipped)),
                _ => None,
            })
            .collect();
        let [(Side::A, skipped)] = skipped[..] else {
            panic!("{reach:?}: {skipped:?}");
        };
        assert_eq!(skipped.reason, SkippedReason::Unreadable);
        assert_eq!(skipped.path().map(|p| p.as_str()), Some("notes.md"));
    }
}

#[tokio::test]
async fn the_profiles_ignore_rules_do_not_hide_the_entrys_own_file() {
    for reach in [Reach::Local, Reach::Served] {
        let site = Site::new();
        let entry = FileEntry {
            a: site.file(Side::A, "x.tmp"),
            b: site.file(Side::B, "x.tmp"),
            site,
            ignore: "\"*.tmp\"",
        };
        entry.put(Side::A, "kept");

        synced(&entry.sync(reach).await, reach);

        assert_eq!(entry.get(Side::B).as_deref(), Some("kept"), "{reach:?}");
    }
}

#[tokio::test]
async fn a_missing_folder_is_refused_and_never_created() {
    for reach in [Reach::Local, Reach::Served] {
        let site = Site::new();
        let entry = FileEntry {
            a: site.file(Side::A, "notes.md"),
            b: site.file(Side::B, "gone/other.md"),
            site,
            ignore: "",
        };
        entry.put(Side::A, "one");

        let finished = entry.sync(reach).await;

        let [RunError::ParentMissing(missing)] = finished.errors()[..] else {
            panic!("{reach:?}: {:?}", finished.errors());
        };
        assert_eq!(missing.side, Side::B);
        assert_eq!(
            missing.folder,
            entry.site.file(Side::B, "gone").to_str().unwrap()
        );
        assert_eq!(finished.exit_code(), 3);
        assert!(!entry.site.file(Side::B, "gone").exists(), "{reach:?}");
        assert_eq!(entry.get(Side::A).as_deref(), Some("one"));
    }
}

async fn refused_as_the_wrong_kind(
    entry: &FileEntry,
    reach: Reach,
    side: Side,
    expected: RootKind,
) {
    let finished = entry.sync(reach).await;
    let [RunError::WrongKind(wrong)] = finished.errors()[..] else {
        panic!("{reach:?}: {:?}", finished.errors());
    };
    assert_eq!((wrong.side, wrong.expected), (side, expected), "{reach:?}");
    assert!(entry.locks().is_empty(), "{reach:?}: {:?}", entry.locks());
    assert!(
        !finished
            .events
            .iter()
            .any(|event| matches!(event, RunEvent::ScanTally { .. })),
        "{reach:?}"
    );
}

#[tokio::test]
async fn a_folder_where_the_entry_syncs_a_file_is_refused_before_anything_is_locked() {
    for reach in [Reach::Local, Reach::Served] {
        let entry = FileEntry::new();
        entry.put(Side::A, "one");
        fs::create_dir(&entry.b).unwrap();
        fs::write(entry.b.join("inside"), "i").unwrap();

        refused_as_the_wrong_kind(&entry, reach, Side::B, RootKind::File).await;

        assert_eq!(entry.get(Side::A).as_deref(), Some("one"));
        assert_eq!(fs::read_to_string(entry.b.join("inside")).unwrap(), "i");
        assert_eq!(listing(&entry, Side::B), ["other.md"]);

        // Positive control: once the folder is gone, the entry syncs and
        // takes its locks.
        fs::remove_dir_all(&entry.b).unwrap();
        synced(&entry.sync(reach).await, reach);
        assert!(!entry.locks().is_empty(), "{reach:?}");
    }
}

#[tokio::test]
async fn a_file_where_a_folder_entry_syncs_a_folder_is_refused_before_anything_is_locked() {
    let site = Site::new();
    fs::remove_dir(site.root(Side::B)).unwrap();
    fs::write(site.root(Side::B), "a file").unwrap();
    site.put(Side::A, "one", "1");
    let entry = FileEntry {
        a: site.root(Side::A),
        b: site.root(Side::B),
        site,
        ignore: "",
    };

    let finished = crate::run::support::sync(&entry.site).await;

    let [RunError::WrongKind(wrong)] = finished.errors()[..] else {
        panic!("{:?}", finished.errors());
    };
    assert_eq!((wrong.side, wrong.expected), (Side::B, RootKind::Folder));
    assert!(entry.locks().is_empty());
    assert_eq!(
        fs::read_to_string(entry.site.root(Side::B)).unwrap(),
        "a file"
    );
}

/// A profile run of `entries` over the real connector, batch.
async fn profile_sync(state: StateDir, entries: &[EffectiveOptions]) -> Vec<EntryOutcome> {
    let connector = Connector::new(state.clone(), None, Tuning::DEFAULT);
    let (sender, mut receiver) = mpsc::channel::<ProfileEvent>(8);
    let draining = tokio::spawn(async move { while receiver.recv().await.is_some() {} });
    let run = ProfileRun::new(sender, state, Tuning::DEFAULT, None, ProfileStop::new());
    let report = with_deadline(
        "the profile run",
        run.execute(
            |options| {
                let connector = &connector;
                async move {
                    connector
                        .connect(options)
                        .await
                        .map(|connected| (connected.a, connected.b, connected.peers))
                }
            },
            entries,
            &mut BatchDecider,
        ),
    )
    .await
    .unwrap();
    draining.await.unwrap();
    report
        .entries
        .into_iter()
        .map(|entry| entry.outcome)
        .collect()
}

#[tokio::test]
async fn a_profile_skips_a_file_entry_whose_folder_is_missing_or_a_folder() {
    let site = Site::new();
    let dir = site.root(Side::A).parent().unwrap().to_path_buf();
    for folder in ["f/a", "f/b", "w/a", "w/b", "d/a", "d/b"] {
        fs::create_dir_all(dir.join(folder)).unwrap();
    }
    fs::write(dir.join("f/a/n.md"), "n").unwrap();
    fs::write(dir.join("w/a/n.md"), "n").unwrap();
    fs::create_dir(dir.join("w/b/n.md")).unwrap();
    fs::write(dir.join("d/a/kept"), "k").unwrap();
    let at = |relative: &str| dir.join(relative).display().to_string();
    let text = format!(
        "[[entries]]\nkind = \"file\"\na = '{}'\nb = '{}'\n\
         [[entries]]\nkind = \"file\"\na = '{}'\nb = '{}'\n\
         [[entries]]\na = '{}'\nb = '{}'\n",
        at("f/a/n.md"),
        at("f/b/gone/n.md"),
        at("w/a/n.md"),
        at("w/b/n.md"),
        at("d/a"),
        at("d/b"),
    );
    let entries = Profile::parse(&text, Platform::HOST)
        .unwrap()
        .options(
            &ProfileName::parse("p").unwrap(),
            &RunFlags::validate(dsync_domain::Command::Sync, Flags::default()).unwrap(),
            &HostFacts::new(Platform::HOST, None, [], "/".to_owned()),
        )
        .unwrap();

    let outcomes = profile_sync(site.state(), &entries).await;

    let [
        EntryOutcome::Skipped(SkipReason::ParentMissing(missing)),
        EntryOutcome::Skipped(SkipReason::WrongKind(wrong)),
        EntryOutcome::Synced(_),
    ] = &outcomes[..]
    else {
        panic!("{outcomes:?}");
    };
    assert_eq!(missing.folder, at("f/b/gone"));
    assert_eq!(wrong.root_path, at("w/b/n.md"));
    assert!(!dir.join("f/b/gone").exists());
    assert_eq!(fs::read_to_string(dir.join("d/b/kept")).unwrap(), "k");
}
