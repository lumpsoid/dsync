//! Every key case of `test/cli/profile/profile_loader_test.dart`, through
//! `Profile::parse` and moved to `[[entries]]`, plus the device-id keys,
//! the entry rules and the range checks. The file-lookup cases (not found,
//! config-dir resolution) belong to the profile store.

use super::*;
use crate::format_version::FormatVersion;
use crate::location::SshForm;

const DEVICE: &str =
    "e3b0:c442:98fc:1c14:9afb:f4c8:996f:b924:27ae:41e4:649b:934c:a495:991b:7852:b855";

fn parse(text: &str) -> Result<Profile, ProfileError> {
    Profile::parse(text, Platform::Unix)
}

fn ok(text: &str) -> Profile {
    parse(text).unwrap_or_else(|e| panic!("{e}"))
}

fn location(profile: &Profile, side: Side) -> Location {
    profile.entries()[0].replica(side).to_location()
}

fn patterns(globs: &[Glob]) -> Vec<&str> {
    globs.iter().map(Glob::as_str).collect()
}

fn words(access: &SshAccess) -> Vec<&str> {
    access.options().iter().map(SshOption::as_str).collect()
}

fn unknown_key(text: &str) -> String {
    match parse(text) {
        Err(ProfileError::UnknownKey(key)) => key,
        other => panic!("expected an unknown key, got {other:?}"),
    }
}

fn invalid_key(text: &str) -> String {
    match parse(text) {
        Err(ProfileError::InvalidValue { key, .. }) => key,
        other => panic!("expected an invalid value, got {other:?}"),
    }
}

const MINIMAL: &str = "[[entries]]\na = \"/a\"\nb = \"/b\"\n";

#[test]
fn loads_the_worked_example_from_spec_12() {
    let profile = ok(r#"
[[entries]]
a = "/home/me/notes"
b = "me@phone:/sdcard/notes"

[rules]
ignore = ["**/.git", "*.tmp", "**/node_modules"]
follow = ["shared"]

[options]
warn_size_bytes = 500_000_000
jobs = 4

[ssh.b]
options = ["-i", "~/.ssh/id_phone"]
command = "/data/data/com.termux/files/usr/bin/dsync"
"#);
    assert!(
        matches!(location(&profile, Side::A), Location::Local(l) if l.path() == "/home/me/notes")
    );
    match location(&profile, Side::B) {
        Location::Ssh(ssh) => {
            assert_eq!(ssh.user(), Some("me"));
            assert_eq!(ssh.host(), "phone");
            assert_eq!(ssh.path(), "/sdcard/notes");
            assert_eq!(ssh.form(), SshForm::Inferred);
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        patterns(profile.rules().ignore()),
        ["**/.git", "*.tmp", "**/node_modules"]
    );
    assert_eq!(patterns(profile.rules().follow()), ["shared"]);
    // TOML permits underscores in integer literals; SPEC §12 uses them.
    assert_eq!(profile.warn_size_bytes(), Some(500_000_000));
    assert_eq!(profile.jobs().map(Jobs::get), Some(4));
    assert_eq!(words(profile.ssh(Side::B)), ["-i", "~/.ssh/id_phone"]);
}

#[test]
fn rules_options_and_ssh_are_optional() {
    let profile = ok(MINIMAL);
    assert!(profile.rules().ignore().is_empty());
    assert!(profile.rules().follow().is_empty());
    assert_eq!(profile.warn_size_bytes(), None);
    assert_eq!(profile.jobs(), None);
    for side in Side::BOTH {
        assert!(profile.ssh(side).options().is_empty());
        assert_eq!(profile.ssh(side).command().as_str(), SshCommand::DEFAULT);
    }
}

#[test]
fn ssh_a_and_ssh_b_configure_each_side_on_its_own() {
    let profile = ok(r#"
[[entries]]
a = "ssh://work:/srv/notes"
b = "ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes"

[ssh.a]
options = ["-p", "2222"]

[ssh.b]
options = ["-i", "~/.ssh/id_ssshd"]
command = "/home/qq/.local/bin/dsync"
"#);
    assert_eq!(words(profile.ssh(Side::A)), ["-p", "2222"]);
    // Unset on this side, so the bare word on the remote PATH stands.
    assert_eq!(profile.ssh(Side::A).command().as_str(), SshCommand::DEFAULT);
    assert_eq!(words(profile.ssh(Side::B)), ["-i", "~/.ssh/id_ssshd"]);
    assert_eq!(
        profile.ssh(Side::B).command().as_str(),
        "/home/qq/.local/bin/dsync"
    );
}

#[test]
fn an_unknown_key_under_ssh_b_is_fatal() {
    let text = format!("{MINIMAL}[ssh.b]\noptoins = [\"-p\", \"2222\"]\n");
    assert_eq!(unknown_key(&text), "ssh.b.optoins");
}

#[test]
fn an_unknown_side_under_ssh_is_fatal() {
    let text = format!("{MINIMAL}[ssh.c]\noptions = [\"-p\", \"2222\"]\n");
    assert_eq!(unknown_key(&text), "ssh.c");
}

#[test]
fn an_empty_ssh_command_or_option_is_fatal_named_by_its_key() {
    for (table, key) in [
        ("command = \"\"", "ssh.b.command"),
        ("options = [\"-p\", \"\"]", "ssh.b.options"),
    ] {
        let text = format!("{MINIMAL}[ssh.b]\n{table}\n");
        assert_eq!(invalid_key(&text), key);
    }
    // Positive control: the same tables with words in them parse.
    ok(&format!(
        "{MINIMAL}[ssh.b]\ncommand = \"x\"\noptions = [\"-p\"]\n"
    ));
}

#[test]
fn file_order_has_no_effect_and_a_may_be_the_remote_side() {
    let profile = ok("[[entries]]\nb = \"/local/notes\"\na = \"me@phone:/sdcard/notes\"\n");
    assert!(matches!(location(&profile, Side::A), Location::Ssh(s) if s.host() == "phone"));
    assert_eq!(location(&profile, Side::B).path(), "/local/notes");
}

#[test]
fn unparseable_toml_is_fatal() {
    assert!(matches!(
        parse("[[entries]\na = \"/a\"\n"),
        Err(ProfileError::Toml(_))
    ));
}

#[test]
fn a_table_defined_twice_is_fatal_as_unparseable_toml() {
    let text = format!("{MINIMAL}[options]\njobs = 1\n[options]\njobs = 2\n");
    assert!(matches!(parse(&text), Err(ProfileError::Toml(_))));
}

#[test]
fn a_missing_location_is_fatal_named_by_its_entry() {
    let missing_b = ProfileError::MissingLocation {
        entry: 0,
        side: Side::B,
    };
    assert_eq!(parse("[[entries]]\na = \"/a\"\n"), Err(missing_b.clone()));
    assert_eq!(parse("[[entries]]\na = \"/a\"\nb = \"\"\n"), Err(missing_b));
    assert_eq!(
        parse(&format!("{MINIMAL}[[entries]]\nb = \"/d\"\n")),
        Err(ProfileError::MissingLocation {
            entry: 1,
            side: Side::A
        })
    );
}

#[test]
fn a_profile_without_entries_is_fatal() {
    assert_eq!(parse("[options]\njobs = 2\n"), Err(ProfileError::NoEntries));
    assert_eq!(parse("entries = []\n"), Err(ProfileError::NoEntries));
    assert_eq!(invalid_key("entries = 1\n"), "entries");
    assert_eq!(invalid_key("entries = [1]\n"), "entries[0]");
    assert_eq!(Profile::new(vec![]), Err(ProfileError::NoEntries));
    // Positive control: one entry is enough.
    assert_eq!(ok(MINIMAL).entries().len(), 1);
}

#[test]
fn the_old_replicas_table_is_an_unknown_key() {
    assert_eq!(
        unknown_key("[replicas]\na = \"/a\"\nb = \"/b\"\n"),
        "replicas"
    );
    assert_eq!(
        unknown_key(&format!("{MINIMAL}[replicas]\na = \"/a\"\n")),
        "replicas"
    );
}

#[test]
fn unknown_tables_and_keys_are_fatal_wherever_they_are() {
    assert_eq!(
        unknown_key(&format!("{MINIMAL}[replicaz]\na = \"/c\"\n")),
        "replicaz"
    );
    assert_eq!(
        unknown_key(&format!("{MINIMAL}c = \"/c\"\n")),
        "entries[0].c"
    );
    assert_eq!(
        unknown_key(&format!(
            "{MINIMAL}[[entries]]\na = \"/c\"\nb = \"/d\"\nc = 1\n"
        )),
        "entries[1].c"
    );
    assert_eq!(
        unknown_key(&format!("[devices]\nc = \"x\"\n{MINIMAL}")),
        "devices.c"
    );
    // The case that would silently stop ignoring **/.git.
    assert_eq!(
        unknown_key(&format!("{MINIMAL}[rules]\nignroe = [\"**/.git\"]\n")),
        "rules.ignroe"
    );
    assert_eq!(
        unknown_key(&format!("{MINIMAL}[options]\nwrn_size_bytes = 100\n")),
        "options.wrn_size_bytes"
    );
}

#[test]
fn the_written_profile_names_its_version_and_one_without_is_1_0() {
    let written = ok(MINIMAL).to_toml();
    assert!(written.starts_with("version = \"1.0\"\n"), "{written}");
    assert_eq!(PROFILE_FORMAT_VERSION, FormatVersion::new(1, 0));
    assert_eq!(ok(&format!("version = \"1.0\"\n{MINIMAL}")), ok(MINIMAL));
    assert_eq!(
        invalid_key(&format!("version = \"one\"\n{MINIMAL}")),
        "version"
    );
    assert_eq!(invalid_key(&format!("version = 1\n{MINIMAL}")), "version");
}

#[test]
fn a_profile_of_another_major_is_refused_naming_both_versions() {
    for (text, found) in [
        ("2.0", FormatVersion::new(2, 0)),
        ("0.9", FormatVersion::new(0, 9)),
    ] {
        let error = parse(&format!("version = \"{text}\"\n{MINIMAL}")).unwrap_err();
        assert_eq!(error, ProfileError::ForeignVersion { found });
        let message = error.to_string();
        assert!(message.contains(&format!("format {text}")), "{message}");
        assert!(message.contains("(format 1.0)"), "{message}");
    }
}

/// A later minor's additions are unknown here by construction; the same
/// keys under this build's own minor are still typos.
#[test]
fn a_later_minor_reads_with_its_unknown_keys_ignored_wherever_they_are() {
    let additions = "[[entries]]\na = \"/a\"\nb = \"/b\"\nc = \"/c\"\n\
                     [rules]\nignore = [\"**/.git\"]\nprune = true\n\
                     [schedule]\nevery = \"1h\"\n\
                     [ssh.a]\ncommand = \"dsync\"\nport = 22\n";
    let later = ok(&format!("version = \"1.3\"\n{additions}"));
    assert_eq!(patterns(later.rules().ignore()), ["**/.git"]);
    assert_eq!(later.ssh(Side::A).command().to_string(), "dsync");

    assert_eq!(
        unknown_key(&format!("version = \"1.0\"\n{additions}")),
        "schedule"
    );
    assert_eq!(unknown_key(additions), "schedule");
}

#[test]
fn locations_parse_through_location_parse() {
    let profile = ok("[[entries]]\na = \"notes\"\nb = \"host:/remote/notes\"\n");
    assert!(matches!(location(&profile, Side::A), Location::Local(l) if l.path() == "notes"));
    assert!(matches!(location(&profile, Side::B), Location::Ssh(s) if s.host() == "host"));
    assert_eq!(
        invalid_key("[[entries]]\na = \"/a\"\nb = \"host:\"\n"),
        "entries[0].b"
    );
}

#[test]
fn a_peer_side_is_keyed_by_its_device_id_for_every_entry() {
    let profile = ok(&format!(
        "[devices]\nb = \"{DEVICE}\"\n\
         [[entries]]\na = \"/a\"\nb = \"peer://phone:/sdcard/notes\"\n\
         [[entries]]\na = \"/c\"\nb = \"peer://phone:/sdcard/music\"\n"
    ));
    for entry in profile.entries() {
        assert_eq!(
            entry
                .replica(Side::B)
                .peer_device()
                .map(ToString::to_string),
            Some(DEVICE.to_owned())
        );
        assert_eq!(entry.replica(Side::A).peer_device(), None);
    }
}

#[test]
fn a_peer_side_without_its_device_id_is_fatal() {
    assert_eq!(
        parse("[[entries]]\na = \"/a\"\nb = \"peer://phone:/sdcard/notes\"\n"),
        Err(ProfileError::MissingDeviceId {
            entry: 0,
            side: Side::B
        })
    );
    // Positive control: with devices.b it parses.
    ok(&format!(
        "[devices]\nb = \"{DEVICE}\"\n[[entries]]\na = \"/a\"\nb = \"peer://phone:/sdcard/notes\"\n"
    ));
}

#[test]
fn a_device_id_for_a_non_peer_side_is_fatal() {
    assert_eq!(
        parse(&format!("[devices]\na = \"{DEVICE}\"\n{MINIMAL}")),
        Err(ProfileError::UnexpectedDeviceId {
            entry: 0,
            side: Side::A
        })
    );
    assert_eq!(
        parse(&format!("[devices]\nb = \"{DEVICE}\"\n{MINIMAL}")),
        Err(ProfileError::UnexpectedDeviceId {
            entry: 0,
            side: Side::B
        })
    );
}

#[test]
fn a_malformed_device_id_is_fatal() {
    let text = "[devices]\nb = \"abcd\"\n[[entries]]\na = \"/a\"\nb = \"peer://p:/x\"\n";
    assert_eq!(invalid_key(text), "devices.b");
}

#[test]
fn jobs_must_be_in_range() {
    for bad in ["0", "-1", "257"] {
        assert_eq!(
            invalid_key(&format!("{MINIMAL}[options]\njobs = {bad}\n")),
            "options.jobs",
            "{bad}"
        );
    }
    for good in ["1", "256"] {
        ok(&format!("{MINIMAL}[options]\njobs = {good}\n"));
    }
}

#[test]
fn warn_size_bytes_must_not_be_negative() {
    assert_eq!(
        invalid_key(&format!("{MINIMAL}[options]\nwarn_size_bytes = -1\n")),
        "options.warn_size_bytes"
    );
    let zero = ok(&format!("{MINIMAL}[options]\nwarn_size_bytes = 0\n"));
    assert_eq!(zero.warn_size_bytes(), Some(0));
}

#[test]
fn values_of_the_wrong_type_are_fatal_named_by_their_key() {
    assert_eq!(
        invalid_key(&format!("{MINIMAL}[options]\njobs = \"4\"\n")),
        "options.jobs"
    );
    assert_eq!(
        invalid_key(&format!("{MINIMAL}[rules]\nignore = \"*.tmp\"\n")),
        "rules.ignore"
    );
    assert_eq!(
        invalid_key(&format!("{MINIMAL}[rules]\nfollow = [1]\n")),
        "rules.follow"
    );
    assert_eq!(
        invalid_key("[[entries]]\na = 1\nb = \"/b\"\n"),
        "entries[0].a"
    );
    assert_eq!(
        invalid_key(&format!("{MINIMAL}[rules]\nignore = [\"a[b\"]\n")),
        "rules.ignore"
    );
    assert_eq!(
        invalid_key("rules = 1\n[[entries]]\na = \"/a\"\nb = \"/b\"\n"),
        "rules"
    );
}

type Expect = fn(&ProfileNameError) -> bool;

#[test]
fn profile_names_are_file_safe() {
    for good in ["notes", "Phone photos", "work-2024_v1.2", "фото"] {
        assert!(ProfileName::parse(good).is_ok(), "{good}");
    }
    let bad: [(&str, Expect); 12] = [
        ("", |e| matches!(e, ProfileNameError::Length)),
        ("a/b", |e| matches!(e, ProfileNameError::Character(_))),
        ("a\\b", |e| matches!(e, ProfileNameError::Character(_))),
        ("a:b", |e| matches!(e, ProfileNameError::Character(_))),
        ("a*b", |e| matches!(e, ProfileNameError::Character(_))),
        ("..", |e| matches!(e, ProfileNameError::Edge(_))),
        (".hidden", |e| matches!(e, ProfileNameError::Edge(_))),
        ("-rf", |e| matches!(e, ProfileNameError::Edge(_))),
        ("trailing.", |e| matches!(e, ProfileNameError::Edge(_))),
        ("con", |e| matches!(e, ProfileNameError::Reserved(_))),
        ("COM1.backup", |e| {
            matches!(e, ProfileNameError::Reserved(_))
        }),
        ("lpt9", |e| matches!(e, ProfileNameError::Reserved(_))),
    ];
    for (text, expected) in bad {
        match ProfileName::parse(text) {
            Ok(name) => panic!("{text:?} accepted as {name}"),
            Err(error) => assert!(expected(&error), "{text:?}: {error:?}"),
        }
    }
    assert!(ProfileName::parse(&"x".repeat(64)).is_ok());
    assert_eq!(
        ProfileName::parse(&"x".repeat(65)),
        Err(ProfileNameError::Length)
    );
    assert!(ProfileName::parse("com0").is_ok());
    assert!(ProfileName::parse("console").is_ok());
}

/// `parse(to_toml(p)) == p`, and the text is stable across a second trip.
fn round_trips(text: &str) -> String {
    let profile = ok(text);
    let written = profile.to_toml();
    assert_eq!(parse(&written), Ok(profile), "{written}");
    assert_eq!(ok(&written).to_toml(), written);
    written
}

#[test]
fn a_profile_round_trips_through_toml() {
    let full = format!(
        r#"
[devices]
b = "{DEVICE}"

[[entries]]
a = "~/notes"
b = "peer://phone:/sdcard/notes"

[rules]
ignore = ["**/.git", "*.tmp"]
follow = ["shared"]

[options]
warn_size_bytes = 500_000_000
jobs = 4

[ssh.a]
options = ["-p", "2222"]
command = "/opt/bin/dsync"
"#
    );
    let written = round_trips(&full);
    assert!(written.contains("[devices]"), "{written}");
    assert!(written.contains("[ssh.a]"), "{written}");

    for text in [
        MINIMAL,
        "[[entries]]\na = \"ssh://me@host:/x\"\nb = \"host2:~/y\"\n",
        "[[entries]]\na = \"unix:///run/s.sock:/x\"\nb = \"C:/not/windows/on/unix\"\n",
        "[[entries]]\na = \"/a\"\nb = \"/b\"\n[ssh.b]\ncommand = \"dsync-dev\"\n",
    ] {
        round_trips(text);
    }
}

#[test]
fn defaults_are_left_out_of_the_written_text() {
    let written = ok(MINIMAL).to_toml();
    for absent in ["[rules]", "[options]", "[ssh", "[devices]", "kind"] {
        assert!(!written.contains(absent), "{absent} in {written}");
    }
    // Positive control: a set option is written.
    assert!(
        ok(&format!("{MINIMAL}[options]\njobs = 2\n"))
            .to_toml()
            .contains("jobs = 2")
    );
}

#[test]
fn a_profile_built_from_values_writes_what_parse_reads_back() {
    let local = ReplicaLocation::new(
        Location::parse("/home/me/notes", Platform::Unix).unwrap(),
        None,
    )
    .unwrap();
    let peer = ReplicaLocation::new(
        Location::parse("peer://phone:/sdcard/notes", Platform::Unix).unwrap(),
        Some(DEVICE.parse().unwrap()),
    )
    .unwrap();
    let rules = RuleSet::new(vec![Glob::new("**/.git").unwrap()], vec![]);
    let entry = Entry::folder(local.clone(), peer.clone()).unwrap();
    let built = Profile::new(vec![entry.clone()])
        .unwrap()
        .with_rules(rules.clone())
        .with_jobs(Jobs::new(3).unwrap());
    assert_eq!(built.entries()[0].replica(Side::A), &local);
    assert_eq!(built.entries()[0].replica(Side::B), &peer);
    assert_eq!(built.rules(), &rules);
    assert_eq!(built.jobs(), Some(Jobs::new(3).unwrap()));
    let written = built.to_toml();
    assert!(written.contains("[devices]"), "{written}");
    assert_eq!(ok(&written), built);

    // Nothing set, nothing written beyond the devices and entries.
    let bare = Profile::new(vec![entry]).unwrap().to_toml();
    assert!(
        !bare.contains("[rules]") && !bare.contains("[options]"),
        "{bare}"
    );
}

const TWO_ENTRIES: &str = r#"
[[entries]]
a = "~/Documents"
b = "peer://phone:/storage/emulated/0/Documents"

[[entries]]
kind = "file"
a = "~/notes.md"
b = "peer://phone:/storage/emulated/0/Notes/notes.md"
"#;

fn with_device(entries: &str) -> String {
    format!("[devices]\nb = \"{DEVICE}\"\n{entries}")
}

#[test]
fn two_entries_one_a_file_round_trip_in_order() {
    let written = round_trips(&with_device(TWO_ENTRIES));
    let profile = ok(&written);
    let kinds: Vec<RootKind> = profile.entries().iter().map(Entry::kind).collect();
    assert_eq!(kinds, [RootKind::Folder, RootKind::File]);
    assert_eq!(location(&profile, Side::A).path(), "~/Documents");
    assert_eq!(
        profile.entries()[1].replica(Side::B).to_location().path(),
        "/storage/emulated/0/Notes/notes.md"
    );
    // `kind` is written for the file only; the folder takes the default.
    assert_eq!(written.matches("kind = \"file\"").count(), 1, "{written}");
    assert!(!written.contains("folder"), "{written}");
}

#[test]
fn kind_defaults_to_folder_and_an_unknown_kind_is_fatal() {
    let folder = "[[entries]]\nkind = \"folder\"\na = \"/a\"\nb = \"/b\"\n";
    assert_eq!(ok(folder), ok(MINIMAL));
    assert_eq!(ok(MINIMAL).entries()[0].kind(), RootKind::Folder);
    for bad in ["\"dir\"", "\"File\"", "1"] {
        let text = format!("[[entries]]\nkind = {bad}\na = \"/a\"\nb = \"/b\"\n");
        assert_eq!(invalid_key(&text), "entries[0].kind", "{bad}");
    }
    // Positive control: a file entry parses.
    let file = ok("[[entries]]\nkind = \"file\"\na = \"/a/x.md\"\nb = \"/b/x.md\"\n");
    assert_eq!(file.entries()[0].kind(), RootKind::File);
}

#[test]
fn a_file_entry_without_a_file_name_is_fatal() {
    for (a, b, key) in [
        ("/home/me/", "/b/x.md", "entries[0].a"),
        ("/a/x.md", "/", "entries[0].b"),
        ("/a/x.md", "host:/srv/", "entries[0].b"),
    ] {
        let text = format!("[[entries]]\nkind = \"file\"\na = \"{a}\"\nb = \"{b}\"\n");
        assert_eq!(invalid_key(&text), key, "{a} {b}");
    }
    // Positive control: the same paths as a folder entry parse.
    ok("[[entries]]\na = \"/home/me/\"\nb = \"/\"\n");
}

#[test]
fn a_peer_path_starting_with_a_tilde_is_fatal() {
    let text = with_device("[[entries]]\na = \"~/Docs\"\nb = \"peer://phone:~/Docs\"\n");
    assert_eq!(invalid_key(&text), "entries[0].b");
    // Positive control: absolute on the peer, `~` on the local side.
    ok(&with_device(
        "[[entries]]\na = \"~/Docs\"\nb = \"peer://phone:/home/u/Docs\"\n",
    ));
}

#[test]
fn every_entry_keeps_each_side_on_one_endpoint() {
    for (second, side) in [
        ("a = \"me@host:/c\"\nb = \"me@phone:/d\"", Side::A),
        ("a = \"/c\"\nb = \"other@phone:/d\"", Side::B),
        ("a = \"/c\"\nb = \"/d\"", Side::B),
        ("a = \"/c\"\nb = \"unix:///s.sock:/d\"", Side::B),
    ] {
        let text = format!("[[entries]]\na = \"/a\"\nb = \"me@phone:/b\"\n[[entries]]\n{second}\n");
        assert_eq!(
            parse(&text),
            Err(ProfileError::MixedEndpoints { side, entry: 1 }),
            "{second}"
        );
    }
    // Positive control: one host per side, however the ssh side is spelled.
    let same = ok("[[entries]]\na = \"/a\"\nb = \"me@phone:/b\"\n\
                   [[entries]]\na = \"/c\"\nb = \"ssh://me@phone:/d\"\n");
    assert_eq!(same.entries().len(), 2);
}
