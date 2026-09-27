//! Every case of `test/cli/options/effective_options_test.dart`, plus the
//! two "same location" cases of `sync_target_test.dart`, plus a profile's
//! entries: one options per entry, and the overlap refusal.

use super::*;
use crate::location::Location;
use crate::platform::Platform;
use crate::profile::ProfileName;
use crate::run_flags::{Command, Flags};
use crate::ssh_access::SshCommand;

fn facts_in(cwd: &str) -> HostFacts {
    HostFacts::new(
        Platform::Unix,
        Some("/home/me".to_owned()),
        [("HOME".to_owned(), "/home/me".to_owned())],
        cwd.to_owned(),
    )
}

fn facts() -> HostFacts {
    facts_in("/")
}

fn flags(flags: Flags) -> RunFlags {
    RunFlags::validate(Command::Sync, flags).unwrap_or_else(|e| panic!("{e}"))
}

fn no_flags() -> RunFlags {
    flags(Flags::default())
}

fn replica(raw: &str) -> ReplicaLocation {
    ReplicaLocation::new(Location::parse(raw, Platform::Unix).unwrap(), None).unwrap()
}

fn name(text: &str) -> ProfileName {
    ProfileName::parse(text).unwrap()
}

fn profile(text: &str) -> Profile {
    Profile::parse(text, Platform::Unix).unwrap_or_else(|e| panic!("{e}"))
}

/// The one entry's options of a single-entry profile.
fn single(name_text: &str, profile: &Profile, run: &RunFlags) -> EffectiveOptions {
    let mut options = profile
        .options(&name(name_text), run, &facts())
        .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(options.len(), 1);
    options.remove(0)
}

const WORK: &str = r#"
[[entries]]
a = "/home/me/notes"
b = "me@phone:/sdcard/notes"
[rules]
ignore = ["*.tmp"]
[options]
warn_size_bytes = 500
jobs = 2
"#;

const BARE: &str = r#"
[[entries]]
a = "/home/me/notes"
b = "me@phone:/sdcard/notes"
"#;

fn work(run: &RunFlags) -> EffectiveOptions {
    single("work", &profile(WORK), run)
}

fn ad_hoc(first: &str, second: &str, run: &RunFlags) -> EffectiveOptions {
    ad_hoc_with(first, second, run, &facts(), &[])
}

fn ad_hoc_with(
    first: &str,
    second: &str,
    run: &RunFlags,
    facts: &HostFacts,
    addresses: &[&str],
) -> EffectiveOptions {
    let addresses: Vec<String> = addresses.iter().map(|a| (*a).to_owned()).collect();
    EffectiveOptions::for_ad_hoc(replica(first), replica(second), run, facts, &addresses)
        .unwrap_or_else(|e| panic!("{e}"))
}

fn options_of(access: &SshAccess) -> Vec<&str> {
    access.options().iter().map(|o| o.as_str()).collect()
}

fn path_of(options: &EffectiveOptions, side: Side) -> String {
    options.replica(side).to_location().path().to_owned()
}

fn host_of(options: &EffectiveOptions, side: Side) -> Option<String> {
    match options.replica(side).to_location() {
        Location::Ssh(ssh) => Some(ssh.host().to_owned()),
        _ => None,
    }
}

fn ignore_of(options: &EffectiveOptions) -> Vec<&str> {
    options.rules.ignore().iter().map(|g| g.as_str()).collect()
}

// -- Profile::options --

#[test]
fn each_side_keeps_its_own_ssh_and_the_flags_reach_both() {
    let two_remotes = profile(
        r#"
[[entries]]
a = "ssh://work:/srv/notes"
b = "ssh://phone:/sdcard/notes"
[ssh.a]
options = ["-p", "2222"]
[ssh.b]
options = ["-i", "/keys/id_phone"]
command = "/opt/bin/dsync"
"#,
    );
    let run = flags(Flags {
        ssh_options: vec!["-v".into()],
        ..Flags::default()
    });
    let effective = single("both", &two_remotes, &run);
    assert_eq!(options_of(effective.ssh(Side::A)), ["-p", "2222", "-v"]);
    assert_eq!(
        options_of(effective.ssh(Side::B)),
        ["-i", "/keys/id_phone", "-v"]
    );
    assert_eq!(
        effective.ssh(Side::A).command().as_str(),
        SshCommand::DEFAULT
    );
    assert_eq!(effective.ssh(Side::B).command().as_str(), "/opt/bin/dsync");
}

#[test]
fn remote_dsync_overrides_every_sides_profile_command() {
    let with_command = profile(
        r#"
[[entries]]
a = "ssh://work:/srv/notes"
b = "ssh://phone:/sdcard/notes"
[ssh.b]
command = "/opt/bin/dsync"
"#,
    );
    let run = flags(Flags {
        remote_dsync: Some("/tmp/build/dsync".into()),
        ..Flags::default()
    });
    let effective = single("both", &with_command, &run);
    assert_eq!(
        effective.ssh(Side::A).command().as_str(),
        "/tmp/build/dsync"
    );
    assert_eq!(
        effective.ssh(Side::B).command().as_str(),
        "/tmp/build/dsync"
    );
}

#[test]
fn a_flag_beats_the_profile_for_warn_size_bytes() {
    let run = flags(Flags {
        warn_size: Some(999),
        ..Flags::default()
    });
    assert_eq!(work(&run).warn_size_bytes, Some(999));
}

#[test]
fn with_no_flag_the_profile_warn_size_bytes_is_kept() {
    assert_eq!(work(&no_flags()).warn_size_bytes, Some(500));
}

#[test]
fn the_profile_warn_size_bytes_beats_the_default() {
    let run = flags(Flags {
        default_warn_size_bytes: Some(7),
        ..Flags::default()
    });
    assert_eq!(work(&run).warn_size_bytes, Some(500));
}

#[test]
fn a_flag_beats_the_default_warn_size_bytes() {
    let run = flags(Flags {
        warn_size: Some(999),
        default_warn_size_bytes: Some(7),
        ..Flags::default()
    });
    assert_eq!(work(&run).warn_size_bytes, Some(999));
    assert_eq!(
        ad_hoc("/home/me/a", "/home/me/b", &run).warn_size_bytes,
        Some(999)
    );
}

#[test]
fn with_neither_a_flag_nor_a_profile_value_the_default_warn_size_bytes_applies() {
    let run = flags(Flags {
        default_warn_size_bytes: Some(7),
        ..Flags::default()
    });
    assert_eq!(
        single("bare", &profile(BARE), &run).warn_size_bytes,
        Some(7)
    );
    assert_eq!(
        ad_hoc("/home/me/a", "/home/me/b", &run).warn_size_bytes,
        Some(7)
    );
}

#[test]
fn a_flag_beats_the_profile_for_jobs() {
    let run = flags(Flags {
        jobs: Some(8),
        ..Flags::default()
    });
    assert_eq!(work(&run).jobs.map(Jobs::get), Some(8));
}

#[test]
fn allow_mass_delete_comes_from_the_flag_alone() {
    let run = flags(Flags {
        allow_mass_delete: true,
        ..Flags::default()
    });
    assert!(work(&run).allow_mass_delete);
    assert!(!work(&no_flags()).allow_mass_delete);
    assert!(ad_hoc("/home/me/a", "/home/me/b", &run).allow_mass_delete);
}

#[test]
fn the_mass_delete_policy_is_the_heads_or_the_default() {
    let run = flags(Flags {
        mass_delete: Some((3, 20)),
        ..Flags::default()
    });
    let heads = MassDeletePolicy::new(3, 20).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(work(&run).mass_delete, heads);
    assert_eq!(ad_hoc("/home/me/a", "/home/me/b", &run).mass_delete, heads);
    assert_eq!(work(&no_flags()).mass_delete, MassDeletePolicy::DEFAULT);
    assert_eq!(
        ad_hoc("/home/me/a", "/home/me/b", &no_flags()).mass_delete,
        MassDeletePolicy::DEFAULT
    );
}

#[test]
fn with_no_flag_the_profile_jobs_is_kept() {
    assert_eq!(work(&no_flags()).jobs.map(Jobs::get), Some(2));
}

#[test]
fn with_neither_a_flag_nor_a_profile_value_the_result_is_none() {
    let effective = single("bare", &profile(BARE), &no_flags());
    assert_eq!(effective.warn_size_bytes, None);
    assert_eq!(effective.jobs, None);
}

#[test]
fn ignore_adds_to_the_profiles_ignore_list() {
    let run = flags(Flags {
        ignore: vec!["*.log".into()],
        ..Flags::default()
    });
    assert_eq!(ignore_of(&work(&run)), ["*.tmp", "*.log"]);
}

#[test]
fn a_profiles_order_is_kept_even_remote_first_and_its_id_is_the_pairs() {
    let remote_first = profile(
        r#"
[[entries]]
a = "me@phone:/sdcard/notes"
b = "/home/me/notes"
"#,
    );
    let effective = single("rev", &remote_first, &no_flags());
    assert_eq!(host_of(&effective, Side::A).as_deref(), Some("phone"));
    assert_eq!(path_of(&effective, Side::B), "/home/me/notes");

    let forward = work(&no_flags());
    assert_eq!(path_of(&forward, Side::A), "/home/me/notes");
    assert_eq!(host_of(&forward, Side::B).as_deref(), Some("phone"));
    // One derivation (plan OQ6): the profile's id is the pair's, whatever
    // the name, and an ad-hoc run over the same pair shares it.
    assert_eq!(effective.entry_id, forward.entry_id);
    let adhoc = ad_hoc("/home/me/notes", "me@phone:/sdcard/notes", &no_flags());
    assert_eq!(adhoc.entry_id, forward.entry_id);
}

#[test]
fn a_profile_whose_replicas_canonicalize_to_the_same_location_is_refused() {
    let same_place = profile(
        r#"
[[entries]]
a = "~/notes"
b = "$HOME/notes/"
"#,
    );
    let error = same_place
        .options(&name("dup"), &no_flags(), &facts())
        .unwrap_err();
    assert_eq!(
        error.to_string(),
        "profile \"dup\": entries[0].a (/home/me/notes) and entries[0].b (/home/me/notes) are \
         the same, or one lies inside the other, once \"~\" and environment variables are \
         expanded; no path of a profile may be, contain or lie inside another"
    );
}

// -- for_ad_hoc --

#[test]
fn the_same_pair_in_both_orders_derives_one_id_and_one_a() {
    let forward = ad_hoc("/home/me/a", "/home/me/b", &no_flags());
    let backward = ad_hoc("/home/me/b", "/home/me/a", &no_flags());
    assert_eq!(forward.entry_id, backward.entry_id);
    assert_eq!(path_of(&forward, Side::A), "/home/me/a");
    assert_eq!(path_of(&forward, Side::B), "/home/me/b");
    assert_eq!(path_of(&backward, Side::A), "/home/me/a");
    assert_eq!(path_of(&backward, Side::B), "/home/me/b");
}

#[test]
fn both_sides_get_the_runs_ssh_flags() {
    let run = flags(Flags {
        ssh_options: vec!["-i".into(), "/keys/id_x".into()],
        remote_dsync: Some("/opt/bin/dsync".into()),
        ..Flags::default()
    });
    let effective = ad_hoc("/home/me/a", "ssh://phone:/sdcard/b", &run);
    for side in Side::BOTH {
        assert_eq!(options_of(effective.ssh(side)), ["-i", "/keys/id_x"]);
        assert_eq!(effective.ssh(side).command().as_str(), "/opt/bin/dsync");
    }
}

#[test]
fn how_a_replica_is_reached_is_not_part_of_its_identity() {
    let plain = ad_hoc("/home/me/a", "ssh://phone:/sdcard/b", &no_flags());
    let run = flags(Flags {
        ssh_options: vec!["-v".into()],
        remote_dsync: Some("/opt/bin/dsync".into()),
        ..Flags::default()
    });
    let with_access = ad_hoc("/home/me/a", "ssh://phone:/sdcard/b", &run);
    assert_eq!(plain.entry_id, with_access.entry_id);
}

#[test]
fn an_ssh_scheme_side_is_remote_whatever_the_addresses_say() {
    let effective = ad_hoc_with(
        "/home/me/notes",
        "ssh://192.168.1.10:/srv/notes",
        &no_flags(),
        &facts(),
        &["192.168.1.10"],
    );
    assert_eq!(path_of(&effective, Side::A), "/home/me/notes");
    assert_eq!(
        host_of(&effective, Side::B).as_deref(),
        Some("192.168.1.10")
    );
}

#[test]
fn a_mixed_pair_keeps_the_local_side_as_a() {
    let effective = ad_hoc("~/notes", "me@phone:/sdcard/notes", &no_flags());
    assert_eq!(host_of(&effective, Side::A), None);
    assert_eq!(host_of(&effective, Side::B).as_deref(), Some("phone"));
    // Locality beats the canonical order: "b@host:/y" sorts first, but
    // "zz" is this machine.
    let local_second = ad_hoc_with("b@host:/y", "zz:/x", &no_flags(), &facts(), &["zz"]);
    assert_eq!(host_of(&local_second, Side::A).as_deref(), Some("zz"));
}

/// A "two remotes" pair is legal in either order at parse time; the
/// addresses reveal one is this machine, and it becomes A.
#[test]
fn locality_is_recomputed_from_the_addresses() {
    let effective = ad_hoc_with(
        "host1:/data",
        "host2:/data",
        &no_flags(),
        &facts(),
        &["host2"],
    );
    assert_eq!(host_of(&effective, Side::A).as_deref(), Some("host2"));
    assert_eq!(host_of(&effective, Side::B).as_deref(), Some("host1"));
    // Control: without the address, canonical order keeps host1 first.
    let unknown = ad_hoc("host1:/data", "host2:/data", &no_flags());
    assert_eq!(host_of(&unknown, Side::A).as_deref(), Some("host1"));
}

#[test]
fn two_local_paths_in_canonical_order_keep_their_typed_order() {
    let effective = ad_hoc("~/aaa", "~/bbb", &no_flags());
    assert_eq!(path_of(&effective, Side::A), "~/aaa");
    assert_eq!(path_of(&effective, Side::B), "~/bbb");
}

#[test]
fn ignore_becomes_the_whole_rule_set() {
    let run = flags(Flags {
        ignore: vec!["*.tmp".into()],
        ..Flags::default()
    });
    assert_eq!(
        ignore_of(&ad_hoc("/home/me/a", "/home/me/b", &run)),
        ["*.tmp"]
    );
}

#[test]
fn warn_size_and_jobs_flags_are_carried_straight_through() {
    let run = flags(Flags {
        warn_size: Some(10),
        jobs: Some(3),
        ..Flags::default()
    });
    let effective = ad_hoc("/home/me/a", "/home/me/b", &run);
    assert_eq!(effective.warn_size_bytes, Some(10));
    assert_eq!(effective.jobs.map(Jobs::get), Some(3));
}

#[test]
fn the_same_canonical_location_is_refused() {
    for (first, second) in [
        ("~/notes", "$HOME/notes"),
        ("~/notes", "/home/me/notes/"),
        ("$HOME/notes", "/home/me/notes/"),
        // sync_target_test's two: the same text, and a trailing slash.
        ("~/notes", "~/notes"),
        ("~/notes", "~/notes/"),
    ] {
        let error = EffectiveOptions::for_ad_hoc(
            replica(first),
            replica(second),
            &no_flags(),
            &facts(),
            &[],
        )
        .unwrap_err();
        assert_eq!(
            error,
            OptionsError::AdHocOverlap {
                first: "/home/me/notes".into(),
                second: "/home/me/notes".into()
            },
            "{first} vs {second}"
        );
        assert!(
            error
                .to_string()
                .starts_with("the two locations are the same")
        );
    }
}

#[test]
fn two_merely_textually_different_locations_are_accepted() {
    ad_hoc("~/notes", "~/backup", &no_flags());
    ad_hoc("~/notes", "~/notes2", &no_flags());
}

#[test]
fn an_ad_hoc_pair_with_one_side_inside_the_other_is_refused() {
    for (first, second) in [
        ("~/notes", "~/notes/inner"),
        ("$HOME/notes/inner/", "/home/me/notes"),
        ("me@phone:/n", "me@phone:/n/x"),
    ] {
        let error = EffectiveOptions::for_ad_hoc(
            replica(first),
            replica(second),
            &no_flags(),
            &facts(),
            &[],
        )
        .unwrap_err();
        assert!(
            matches!(error, OptionsError::AdHocOverlap { .. }),
            "{first} vs {second}: {error:?}"
        );
    }
    // Positive controls: a sibling, and the same path on two endpoints.
    ad_hoc("~/notes", "~/notesx/inner", &no_flags());
    ad_hoc("/n/x", "me@phone:/n", &no_flags());
}

// -- relative local paths (the working directory) --

#[test]
fn one_relative_path_from_two_working_directories_is_two_pairs() {
    let proj1 = ad_hoc_with(
        "notes",
        "me@phone:/n",
        &no_flags(),
        &facts_in("/home/me/proj1"),
        &[],
    );
    let proj2 = ad_hoc_with(
        "notes",
        "me@phone:/n",
        &no_flags(),
        &facts_in("/home/me/proj2"),
        &[],
    );
    assert_ne!(proj1.entry_id, proj2.entry_id);
}

#[test]
fn a_relative_path_derives_the_id_of_its_absolute_spelling() {
    let relative = ad_hoc_with(
        "notes",
        "me@phone:/n",
        &no_flags(),
        &facts_in("/home/me/proj1"),
        &[],
    );
    let absolute = ad_hoc("/home/me/proj1/notes", "me@phone:/n", &no_flags());
    assert_eq!(relative.entry_id, absolute.entry_id);
}

#[test]
fn a_relative_remote_path_is_left_alone_whatever_the_working_directory() {
    let with_cwd = ad_hoc_with(
        "/home/me/notes",
        "me@phone:notes",
        &no_flags(),
        &facts_in("/home/me/proj1"),
        &[],
    );
    let other_cwd = ad_hoc_with(
        "/home/me/notes",
        "me@phone:notes",
        &no_flags(),
        &facts_in("/elsewhere"),
        &[],
    );
    assert_eq!(with_cwd.entry_id, other_cwd.entry_id);
    assert_eq!(path_of(&with_cwd, Side::B), "notes");
}

// -- a profile's entries --

/// `Profile::options`' error, as the two sides it names.
fn overlap(text: &str, facts: &HostFacts, platform: Platform) -> Option<(String, String)> {
    let profile = Profile::parse(text, platform).unwrap_or_else(|e| panic!("{e}"));
    match profile.options(&name("p"), &no_flags(), facts) {
        Ok(_) => None,
        Err(OptionsError::EntriesOverlap { first, second, .. }) => Some((first, second)),
        Err(other) => panic!("{other}"),
    }
}

fn unix_overlap(text: &str) -> Option<(String, String)> {
    overlap(text, &facts(), Platform::Unix)
}

fn two_entries(first: (&str, &str), second: (&str, &str)) -> String {
    format!(
        "[[entries]]\na = \"{}\"\nb = \"{}\"\n[[entries]]\na = \"{}\"\nb = \"{}\"\n",
        first.0, first.1, second.0, second.1
    )
}

fn named(first: &str, second: &str) -> Option<(String, String)> {
    Some((first.to_owned(), second.to_owned()))
}

#[test]
fn every_entry_gets_its_options_in_entry_order() {
    let text = two_entries(("/home/me/a", "me@phone:/a"), ("/home/me/b", "me@phone:/b"));
    let options = profile(&text)
        .options(&name("two"), &no_flags(), &facts())
        .unwrap();
    let paths: Vec<String> = options.iter().map(|o| path_of(o, Side::A)).collect();
    assert_eq!(paths, ["/home/me/a", "/home/me/b"]);
    assert_ne!(options[0].entry_id, options[1].entry_id);
    // Each entry's id is its pair's, as an ad-hoc run derives it.
    let adhoc = ad_hoc("/home/me/b", "me@phone:/b", &no_flags());
    assert_eq!(options[1].entry_id, adhoc.entry_id);
    assert!(options.iter().all(|o| o.kind() == RootKind::Folder));
    assert!(options.iter().all(|o| o.as_path().is_none()));
}

#[test]
fn entries_overlapping_on_side_a_are_refused() {
    let b = |n| format!("me@phone:/n{n}");
    for (first, second) in [
        // Equal, however spelled.
        ("/home/me/x", "~/x"),
        // Nested, and containing.
        ("/home/me/x", "/home/me/x/y"),
        ("/home/me/x/y", "/home/me/x"),
        // A trailing separator changes nothing.
        ("/home/me/x/", "/home/me/x/y"),
        // `~` and `$HOME` spellings.
        ("~/x", "$HOME/x/y"),
        ("${HOME}/x/y", "~/x"),
    ] {
        let text = two_entries((first, &b(1)), (second, &b(2)));
        assert_eq!(
            unix_overlap(&text),
            named("entries[0].a", "entries[1].a"),
            "{first} vs {second}"
        );
    }
    // Positive controls: siblings, and a name that merely extends another.
    for (first, second) in [("/home/me/x", "/home/me/y"), ("/a/b", "/a/bc")] {
        let text = two_entries((first, &b(1)), (second, &b(2)));
        assert_eq!(unix_overlap(&text), None, "{first} vs {second}");
    }
}

#[test]
fn entries_overlapping_on_side_b_are_refused() {
    let text = two_entries(("/x", "me@phone:/n"), ("/y", "me@phone:/n/sub"));
    assert_eq!(unix_overlap(&text), named("entries[0].b", "entries[1].b"));
    // Positive control: sibling far paths.
    let text = two_entries(("/x", "me@phone:/n"), ("/y", "me@phone:/n2"));
    assert_eq!(unix_overlap(&text), None);
}

#[test]
fn a_file_entry_inside_a_folder_entry_is_refused() {
    let text = "[[entries]]\na = \"/home/me/docs\"\nb = \"me@phone:/docs\"\n\
                [[entries]]\nkind = \"file\"\na = \"/home/me/docs/notes.md\"\n\
                b = \"me@phone:/notes.md\"\n";
    assert_eq!(unix_overlap(text), named("entries[0].a", "entries[1].a"));
    let text = "[[entries]]\na = \"/home/me/docs\"\nb = \"me@phone:/docs\"\n\
                [[entries]]\nkind = \"file\"\na = \"/home/me/notes.md\"\n\
                b = \"me@phone:/docs/notes.md\"\n";
    assert_eq!(unix_overlap(text), named("entries[0].b", "entries[1].b"));
}

#[test]
fn one_entrys_a_inside_anothers_b_is_refused_when_both_sides_are_this_host() {
    let text = two_entries(
        ("/home/me/a", "/home/me/b"),
        ("/home/me/c", "/home/me/a/in"),
    );
    assert_eq!(unix_overlap(&text), named("entries[0].a", "entries[1].b"));
    // Positive control: all four apart.
    let text = two_entries(("/home/me/a", "/home/me/b"), ("/home/me/c", "/home/me/d"));
    assert_eq!(unix_overlap(&text), None);
    // The same path on two endpoints is two trees.
    let text = two_entries(("/n", "me@phone:/m"), ("/m", "me@phone:/n"));
    assert_eq!(unix_overlap(&text), None);
}

#[test]
fn an_entrys_own_a_inside_its_b_is_refused() {
    for (a, b) in [("/home/me/x/y", "/home/me/x"), ("~/x", "/home/me/x/y/")] {
        let text = format!("[[entries]]\na = \"{a}\"\nb = \"{b}\"\n");
        assert_eq!(
            unix_overlap(&text),
            named("entries[0].a", "entries[0].b"),
            "{a} {b}"
        );
    }
    // Positive control: a sibling.
    assert_eq!(
        unix_overlap("[[entries]]\na = \"/home/me/x\"\nb = \"/home/me/xy\"\n"),
        None
    );
}

#[test]
fn windows_paths_overlap_by_windows_rules() {
    let windows = HostFacts::new(
        Platform::Windows,
        Some("C:\\Users\\Me".to_owned()),
        [],
        "C:\\".to_owned(),
    );
    let text = two_entries(
        ("C:\\\\Users\\\\Me\\\\Docs", "me@pc:/a"),
        ("c:/users/me/docs/Sub", "me@pc:/b"),
    );
    assert_eq!(
        overlap(&text, &windows, Platform::Windows),
        named("entries[0].a", "entries[1].a")
    );
    // `~/` expands to the Windows home, mixing separators.
    let text = two_entries(
        ("~/Docs", "me@pc:/a"),
        ("C:\\\\USERS\\\\me\\\\docs", "me@pc:/b"),
    );
    assert_eq!(
        overlap(&text, &windows, Platform::Windows),
        named("entries[0].a", "entries[1].a")
    );
    // Positive control: a sibling whose name extends the other.
    let text = two_entries(
        ("C:\\\\Users\\\\Me\\\\Docs", "me@pc:/a"),
        ("C:\\\\Users\\\\Me\\\\Docs2", "me@pc:/b"),
    );
    assert_eq!(overlap(&text, &windows, Platform::Windows), None);
}

#[test]
fn a_single_file_entry_runs_beside_a_folder_entry() {
    let text = "[[entries]]\na = \"/home/me/docs\"\nb = \"me@phone:/docs\"\n\
                [[entries]]\nkind = \"file\"\na = \"/home/me/notes.md\"\n\
                b = \"me@phone:/notes.md\"\n";
    let options = profile(text)
        .options(&name("p"), &no_flags(), &facts())
        .unwrap();
    let kinds: Vec<RootKind> = options.iter().map(EffectiveOptions::kind).collect();
    assert_eq!(kinds, [RootKind::Folder, RootKind::File]);
    assert_eq!(options[1].as_path().map(RelPath::as_str), Some("notes.md"));
}

/// What a file entry's options carry.
#[test]
fn a_file_entrys_options_carry_its_kind_name_and_own_id() {
    let text = "[[entries]]\nkind = \"file\"\na = \"/home/me/notes.md\"\n\
                b = \"me@phone:/n/renamed.md\"\n";
    let profile = profile(text);
    let entry = &profile.entries()[0];
    let [a, b] = [Side::A, Side::B].map(|side| CanonicalSide::of(entry.replica(side), &facts()));
    let (a, b) = (a.unwrap(), b.unwrap());
    let options = EffectiveOptions::for_entry(&profile, entry, (&a, &b), &no_flags());
    assert_eq!(options.kind(), RootKind::File);
    assert_eq!(options.as_path().map(RelPath::as_str), Some("notes.md"));
    assert_eq!(options.entry_id, EntryId::for_entry(RootKind::File, &a, &b));
    assert_ne!(options.entry_id, EntryId::for_pair(&a, &b));
}
