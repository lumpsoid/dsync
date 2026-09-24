//! Every key case of `test/cli/profile/profile_loader_test.dart`, through
//! `Profile::parse`, plus the head's device-id keys and the range checks.
//! The file-lookup cases (not found, config-dir resolution) belong to the
//! profile store (phase 5).

use super::*;
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
    profile.replica(side).to_location()
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

const MINIMAL: &str = "[replicas]\na = \"/a\"\nb = \"/b\"\n";

#[test]
fn loads_the_worked_example_from_spec_12() {
    let profile = ok(r#"
[replicas]
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
[replicas]
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
    let profile = ok("[replicas]\nb = \"/local/notes\"\na = \"me@phone:/sdcard/notes\"\n");
    assert!(matches!(location(&profile, Side::A), Location::Ssh(s) if s.host() == "phone"));
    assert_eq!(location(&profile, Side::B).path(), "/local/notes");
}

#[test]
fn unparseable_toml_is_fatal() {
    assert!(matches!(
        parse("[replicas\na = \"/a\"\n"),
        Err(ProfileError::Toml(_))
    ));
}

#[test]
fn a_table_defined_twice_is_fatal_as_unparseable_toml() {
    let text = format!("{MINIMAL}\n[replicas]\na = \"/c\"\nb = \"/d\"\n");
    assert!(matches!(parse(&text), Err(ProfileError::Toml(_))));
}

#[test]
fn a_missing_replica_is_fatal() {
    assert_eq!(
        parse("[replicas]\na = \"/a\"\n"),
        Err(ProfileError::MissingReplica(Side::B))
    );
    assert_eq!(
        parse("[replicas]\na = \"/a\"\nb = \"\"\n"),
        Err(ProfileError::MissingReplica(Side::B))
    );
}

#[test]
fn an_absent_replicas_table_is_fatal_as_a_missing_replica() {
    assert_eq!(
        parse("[options]\njobs = 2\n"),
        Err(ProfileError::MissingReplica(Side::A))
    );
}

#[test]
fn unknown_tables_and_keys_are_fatal_wherever_they_are() {
    assert_eq!(
        unknown_key(&format!("{MINIMAL}[replicaz]\na = \"/c\"\n")),
        "replicaz"
    );
    assert_eq!(unknown_key(&format!("{MINIMAL}c = \"/c\"\n")), "replicas.c");
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
fn replicas_parse_through_location_parse() {
    let profile = ok("[replicas]\na = \"notes\"\nb = \"host:/remote/notes\"\n");
    assert!(matches!(location(&profile, Side::A), Location::Local(l) if l.path() == "notes"));
    assert!(matches!(location(&profile, Side::B), Location::Ssh(s) if s.host() == "host"));
    assert_eq!(
        invalid_key("[replicas]\na = \"/a\"\nb = \"host:\"\n"),
        "replicas.b"
    );
}

#[test]
fn a_peer_replica_is_keyed_by_its_device_id() {
    let profile = ok(&format!(
        "[replicas]\na = \"/a\"\nb = \"peer://phone:/sdcard/notes\"\nb_device_id = \"{DEVICE}\"\n"
    ));
    assert_eq!(
        profile
            .replica(Side::B)
            .peer_device()
            .map(ToString::to_string),
        Some(DEVICE.to_owned())
    );
    assert_eq!(profile.replica(Side::A).peer_device(), None);
}

#[test]
fn a_peer_replica_without_a_device_id_is_fatal() {
    assert_eq!(
        parse("[replicas]\na = \"/a\"\nb = \"peer://phone:/sdcard/notes\"\n"),
        Err(ProfileError::MissingDeviceId { side: Side::B })
    );
}

#[test]
fn a_device_id_for_a_non_peer_replica_is_fatal() {
    assert_eq!(
        parse(&format!("{MINIMAL}a_device_id = \"{DEVICE}\"\n")),
        Err(ProfileError::UnexpectedDeviceId { side: Side::A })
    );
}

#[test]
fn a_malformed_device_id_is_fatal() {
    let text = "[replicas]\na = \"/a\"\nb = \"peer://p:/x\"\nb_device_id = \"abcd\"\n";
    assert_eq!(invalid_key(text), "replicas.b_device_id");
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
    assert_eq!(invalid_key("[replicas]\na = 1\nb = \"/b\"\n"), "replicas.a");
    assert_eq!(
        invalid_key(&format!("{MINIMAL}[rules]\nignore = [\"a[b\"]\n")),
        "rules.ignore"
    );
    assert_eq!(
        invalid_key("rules = 1\n[replicas]\na = \"/a\"\nb = \"/b\"\n"),
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
[replicas]
a = "~/notes"
b = "peer://phone:/sdcard/notes"
b_device_id = "{DEVICE}"

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
    assert!(written.contains("b_device_id"), "{written}");
    assert!(written.contains("[ssh.a]"), "{written}");

    for text in [
        MINIMAL,
        "[replicas]\na = \"ssh://me@host:/x\"\nb = \"host2:~/y\"\n",
        "[replicas]\na = \"unix:///run/s.sock:/x\"\nb = \"C:/not/windows/on/unix\"\n",
        "[replicas]\na = \"/a\"\nb = \"/b\"\n[ssh.b]\ncommand = \"dsync-dev\"\n",
    ] {
        round_trips(text);
    }
}

#[test]
fn defaults_are_left_out_of_the_written_text() {
    let written = ok(MINIMAL).to_toml();
    for absent in ["[rules]", "[options]", "[ssh", "device_id"] {
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
    let built = Profile::new(local.clone(), peer.clone())
        .with_rules(rules.clone())
        .with_jobs(Jobs::new(3).unwrap());
    assert_eq!(built.replica(Side::A), &local);
    assert_eq!(built.replica(Side::B), &peer);
    assert_eq!(built.rules(), &rules);
    assert_eq!(built.jobs(), Some(Jobs::new(3).unwrap()));
    let written = built.to_toml();
    assert!(written.contains("b_device_id"), "{written}");
    assert_eq!(ok(&written), built);

    // Nothing set, nothing written beyond the replicas.
    let bare = Profile::new(local, peer).to_toml();
    assert!(
        !bare.contains("[rules]") && !bare.contains("[options]"),
        "{bare}"
    );
}
