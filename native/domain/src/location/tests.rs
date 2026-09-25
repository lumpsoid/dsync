//! Every case of `test/dsync_core/models/location_test.dart`, plus the
//! Windows rules (drive letters, `unix://` refused).

use super::*;

fn parse(raw: &str) -> Location {
    Location::parse(raw, Platform::Unix).unwrap_or_else(|e| panic!("{raw:?}: {e}"))
}

fn ssh(raw: &str) -> SshLocation {
    match parse(raw) {
        Location::Ssh(ssh) => ssh,
        other => panic!("{raw:?} parsed as {other:?}"),
    }
}

fn unix(raw: &str) -> UnixLocation {
    match parse(raw) {
        Location::Unix(unix) => unix,
        other => panic!("{raw:?} parsed as {other:?}"),
    }
}

fn peer(raw: &str) -> PeerLocation {
    match parse(raw) {
        Location::Peer(peer) => peer,
        other => panic!("{raw:?} parsed as {other:?}"),
    }
}

fn assert_local(raw: &str) {
    match parse(raw) {
        Location::Local(local) => assert_eq!(local.path(), raw),
        other => panic!("{raw:?} parsed as {other:?}"),
    }
}

fn assert_rejected(raw: &str) {
    if let Ok(location) = Location::parse(raw, Platform::Unix) {
        panic!("{raw:?} parsed as {location:?}");
    }
}

fn addresses(list: &[&str]) -> Vec<String> {
    list.iter().map(|a| (*a).to_owned()).collect()
}

// group: Location.parse

#[test]
fn absolute_path_has_no_user_or_host() {
    assert_local("/abs/path");
}

#[test]
fn user_at_host_colon_path_splits_into_all_three_parts() {
    let location = ssh("me@phone:/sdcard/notes");
    assert_eq!(location.user(), Some("me"));
    assert_eq!(location.host(), "phone");
    assert_eq!(location.path(), "/sdcard/notes");
    assert_eq!(location.form(), SshForm::Inferred);
}

#[test]
fn host_colon_path_has_no_user() {
    let location = ssh("phone:/sdcard/notes");
    assert_eq!(location.user(), None);
    assert_eq!(location.host(), "phone");
    assert_eq!(location.path(), "/sdcard/notes");
}

#[test]
fn relative_path_with_a_colon_still_splits_as_host_path() {
    let location = ssh("host:notes");
    assert_eq!(location.host(), "host");
    assert_eq!(location.path(), "notes");
}

#[test]
fn relative_local_paths_have_no_user_or_host() {
    // SPEC §2 says "a local path", not "an absolute local path".
    for relative in ["notes", "./notes", "../notes", "~/notes", "~"] {
        assert_local(relative);
    }
}

#[test]
fn a_colon_after_the_first_slash_belongs_to_the_path() {
    assert_local("./log:old");
}

#[test]
fn an_at_after_the_host_separator_belongs_to_the_path() {
    let location = ssh("phone:/sdcard/a@b");
    assert_eq!(location.user(), None);
    assert_eq!(location.host(), "phone");
    assert_eq!(location.path(), "/sdcard/a@b");
}

#[test]
fn a_bare_user_at_host_without_a_path_is_a_local_path() {
    // No colon, so nothing marks it as remote; a file may be named that.
    assert_local("user@host");
}

#[test]
fn rejects_invalid_unschemed_locations() {
    for invalid in ["", "host:", ":path", "@host:path", "user@:path"] {
        assert_rejected(invalid);
    }
    assert_eq!(
        Location::parse("", Platform::Unix),
        Err(LocationError::Empty)
    );
    assert!(matches!(
        Location::parse("a\0b", Platform::Unix),
        Err(LocationError::Nul(_))
    ));
}

// group: the ssh:// form

#[test]
fn a_destination_containing_slashes_is_one_destination_not_a_path() {
    let location = ssh("ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes");
    assert_eq!(location.user(), Some("qq"));
    assert_eq!(location.host(), "unix/run/ssh-unix-local/socket");
    assert_eq!(location.path(), "/tmp/notes");
    assert_eq!(location.form(), SshForm::Declared);
    // Under the colon-before-slash rule the same string is a local path.
    assert_local("unix/run/ssh-unix-local/socket:/tmp/notes");
}

#[test]
fn a_bare_alias_needs_no_user() {
    let location = ssh("ssh://phone:/sdcard/notes");
    assert_eq!(location.user(), None);
    assert_eq!(location.host(), "phone");
    assert_eq!(location.path(), "/sdcard/notes");
    assert_eq!(location.form(), SshForm::Declared);
    assert_eq!(location.destination(), "phone");
    assert_eq!(ssh("ssh://me@phone:/x").destination(), "me@phone");
}

#[test]
fn ssh_only_the_first_colon_separates() {
    let location = ssh("ssh://alias:/srv/log:old");
    assert_eq!(location.host(), "alias");
    assert_eq!(location.path(), "/srv/log:old");
}

#[test]
fn ssh_a_relative_remote_path_is_left_for_the_far_side() {
    assert_eq!(ssh("ssh://alias:notes").path(), "notes");
}

#[test]
fn ssh_a_missing_separator_says_which_one_is_missing() {
    let error = Location::parse("ssh://alias/srv/notes", Platform::Unix)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default();
    assert!(error.contains("\":\""), "{error}");
    assert!(error.contains("ssh destination"), "{error}");
}

#[test]
fn rejects_invalid_ssh_locations() {
    for invalid in [
        "ssh://",
        "ssh://:",
        "ssh://alias:",
        "ssh://:/path",
        "ssh://@alias:/path",
    ] {
        assert_rejected(invalid);
    }
}

// group: the unix:// form

#[test]
fn unix_splits_socket_path_from_replica_path_at_the_first_colon() {
    let location = unix("unix:///run/user/1000/dsync.sock:/home/me/notes");
    assert_eq!(location.socket(), "/run/user/1000/dsync.sock");
    assert_eq!(location.path(), "/home/me/notes");
    // Unschemed, the same string is not a remote location at all.
    assert_local("/run/dsync.sock:/home/me/notes");
}

#[test]
fn unix_no_user_is_split_off() {
    let location = unix("unix:///run/a@b.sock:/srv/notes");
    assert_eq!(location.socket(), "/run/a@b.sock");
    assert_eq!(location.path(), "/srv/notes");
}

#[test]
fn unix_only_the_first_colon_separates() {
    let location = unix("unix:///run/d.sock:/srv/log:old");
    assert_eq!(location.socket(), "/run/d.sock");
    assert_eq!(location.path(), "/srv/log:old");
}

#[test]
fn unix_a_relative_replica_path_is_left_for_the_far_side() {
    assert_eq!(unix("unix:///run/d.sock:notes").path(), "notes");
}

#[test]
fn unix_a_missing_separator_says_which_one_is_missing() {
    let error = Location::parse("unix:///run/d.sock", Platform::Unix)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default();
    assert!(error.contains("\":\""), "{error}");
    assert!(error.contains("socket path"), "{error}");
}

#[test]
fn only_a_unix_location_has_a_socket() {
    // Dart's `socketPath is null for every other form`: here the socket
    // exists only on the Unix variant, so the other forms cannot have one.
    for raw in [
        "/abs/path",
        "me@phone:/notes",
        "ssh://phone:/notes",
        "peer://phone:/n",
    ] {
        assert!(!matches!(parse(raw), Location::Unix(_)), "{raw}");
    }
    assert!(matches!(parse("unix:///d.sock:/n"), Location::Unix(_)));
}

#[test]
fn rejects_invalid_unix_locations() {
    for invalid in ["unix://", "unix://:", "unix:///run/d.sock:"] {
        assert_rejected(invalid);
    }
}

// group: the peer:// form

#[test]
fn peer_splits_device_name_from_replica_path_at_the_first_colon() {
    let location = peer("peer://phone:/sdcard/notes");
    assert_eq!(location.device().as_str(), "phone");
    assert_eq!(location.path(), "/sdcard/notes");
    assert_eq!(ssh("phone:/sdcard/notes").form(), SshForm::Inferred);
}

#[test]
fn peer_no_user_is_split_off() {
    let location = peer("peer://a@b:/srv/notes");
    assert_eq!(location.device().as_str(), "a@b");
    assert_eq!(location.path(), "/srv/notes");
}

#[test]
fn peer_only_the_first_colon_separates() {
    let location = peer("peer://phone:/srv/log:old");
    assert_eq!(location.device().as_str(), "phone");
    assert_eq!(location.path(), "/srv/log:old");
}

#[test]
fn peer_a_relative_replica_path_is_left_for_the_far_side() {
    assert_eq!(peer("peer://phone:notes").path(), "notes");
}

#[test]
fn peer_a_missing_separator_says_which_one_is_missing() {
    let error = Location::parse("peer://phone", Platform::Unix)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default();
    assert!(error.contains("\":\""), "{error}");
    assert!(error.contains("device name"), "{error}");
}

#[test]
fn only_a_peer_location_has_a_device_name() {
    // Dart's `deviceName is null for every other form` and `socketPath is
    // null for a peer:// location`: one variant, one "where".
    for raw in [
        "/abs/path",
        "me@phone:/notes",
        "ssh://phone:/notes",
        "unix:///run/d.sock:/notes",
    ] {
        assert!(!matches!(parse(raw), Location::Peer(_)), "{raw}");
    }
    assert!(matches!(
        parse("peer://phone:/srv/notes"),
        Location::Peer(_)
    ));
}

#[test]
fn rejects_invalid_peer_locations() {
    for invalid in ["peer://", "peer://:", "peer://phone:"] {
        assert_rejected(invalid);
    }
}

// group: Location.toString

#[test]
fn spells_every_form_back_exactly_as_written() {
    for raw in [
        "/abs/path",
        "notes",
        "./log:old",
        "phone:/sdcard/notes",
        "me@phone:/sdcard/notes",
        "ssh://phone:/sdcard/notes",
        "ssh://qq@unix/run/ssh-unix-local/socket:/tmp/notes",
        "unix:///run/user/1000/dsync.sock:/home/me/notes",
        "peer://phone:/sdcard/notes",
    ] {
        assert_eq!(parse(raw).to_string(), raw);
    }
}

// group: Location.expandedPath

#[test]
fn expands_a_leading_tilde_from_home() {
    assert_eq!(
        parse("~/notes").expanded_path(Some("/home/me")),
        Ok("/home/me/notes".to_owned())
    );
}

#[test]
fn expands_a_bare_tilde_to_home_itself() {
    assert_eq!(
        parse("~").expanded_path(Some("/home/me")),
        Ok("/home/me".to_owned())
    );
}

#[test]
fn leaves_a_path_that_only_starts_with_tilde_alone() {
    assert_eq!(
        parse("~notes").expanded_path(Some("/home/me")),
        Ok("~notes".to_owned())
    );
}

#[test]
fn leaves_an_ordinary_path_alone() {
    assert_eq!(
        parse("./notes").expanded_path(None),
        Ok("./notes".to_owned())
    );
}

#[test]
fn fails_loudly_rather_than_producing_a_path_without_home() {
    assert!(parse("~/notes").expanded_path(None).is_err());
    assert!(parse("~/notes").expanded_path(Some("")).is_err());
}

// group: Location.classify

#[test]
fn absent_host_is_in_process() {
    assert_eq!(parse("/abs/path").locality(&[]), Locality::InProcess);
}

#[test]
fn localhost_is_in_process() {
    assert_eq!(
        parse("localhost:/abs/path").locality(&[]),
        Locality::InProcess
    );
}

#[test]
fn an_address_of_this_machine_is_in_process() {
    let location = parse("192.168.1.10:/abs/path");
    assert_eq!(
        location.locality(&addresses(&["192.168.1.10"])),
        Locality::InProcess
    );
    // Positive control: the same location is remote when the list lacks it.
    assert_eq!(
        location.locality(&addresses(&["10.0.0.1"])),
        Locality::Remote
    );
}

#[test]
fn any_other_host_is_remote() {
    assert_eq!(
        parse("me@phone:/sdcard/notes").locality(&addresses(&["192.168.1.10"])),
        Locality::Remote
    );
}

#[test]
fn an_ssh_destination_is_remote_even_when_it_is_this_machine() {
    assert_eq!(
        parse("ssh://192.168.1.10:/abs/path").locality(&addresses(&["192.168.1.10"])),
        Locality::Remote
    );
    assert_eq!(
        parse("ssh://localhost:/abs/path").locality(&[]),
        Locality::Remote
    );
}

#[test]
fn a_unix_location_is_remote_although_the_socket_is_right_here() {
    let location = parse("unix:///run/d.sock:/srv/notes");
    assert_eq!(location.locality(&[]), Locality::Remote);
    assert_eq!(
        location.locality(&addresses(&["127.0.0.1"])),
        Locality::Remote
    );
}

#[test]
fn a_peer_location_is_remote_a_device_name_has_no_address() {
    let location = parse("peer://phone:/srv/notes");
    assert_eq!(location.locality(&[]), Locality::Remote);
    assert_eq!(location.locality(&addresses(&["phone"])), Locality::Remote);
}

// group: Location.consultsLocalAddresses

#[test]
fn only_a_host_this_tool_would_have_to_recognize_needs_the_list() {
    assert!(!parse("/abs/path").consults_local_addresses());
    assert!(parse("phone:/notes").consults_local_addresses());
    assert!(!parse("ssh://phone:/notes").consults_local_addresses());
    assert!(!parse("unix:///run/d.sock:/notes").consults_local_addresses());
    assert!(!parse("peer://phone:/notes").consults_local_addresses());
}

// Windows rules, taken as a passed-in platform so they run on every host.

#[test]
fn a_drive_letter_is_a_local_path_on_windows_and_a_host_elsewhere() {
    for raw in ["C:\\notes", "C:/notes", "d:"] {
        match Location::parse(raw, Platform::Windows) {
            Ok(Location::Local(local)) => assert_eq!(local.path(), raw),
            other => panic!("{raw:?} on Windows: {other:?}"),
        }
    }
    // Two letters are a host on Windows too; one is a host elsewhere.
    assert!(matches!(
        Location::parse("pc:/notes", Platform::Windows),
        Ok(Location::Ssh(_))
    ));
    assert_eq!(ssh("C:/notes").host(), "C");
}

#[test]
fn unix_is_refused_at_parse_on_windows() {
    assert!(matches!(
        Location::parse("unix:///run/d.sock:/srv/notes", Platform::Windows),
        Err(LocationError::UnixUnsupported(_))
    ));
    // Positive control: the same text parses on unix.
    assert!(matches!(
        Location::parse("unix:///run/d.sock:/srv/notes", Platform::Unix),
        Ok(Location::Unix(_))
    ));
}

#[cfg(windows)]
#[test]
fn unix_is_refused_by_the_real_platform_entry_point_on_windows() {
    assert!(matches!(
        "unix:///run/d.sock:/srv/notes".parse::<Location>(),
        Err(LocationError::UnixUnsupported(_))
    ));
}

#[cfg(unix)]
#[test]
fn unix_is_accepted_by_the_real_platform_entry_point_on_unix() {
    assert!(matches!(
        "unix:///run/d.sock:/srv/notes".parse::<Location>(),
        Ok(Location::Unix(_))
    ));
}

#[test]
fn a_device_name_is_validated_as_a_peer_name() {
    assert!(matches!(
        Location::parse("peer://a\tb:/x", Platform::Unix),
        Err(LocationError::DeviceName { .. })
    ));
}

#[test]
fn a_local_location_from_a_picked_folder_must_read_back_as_local() {
    let local = Location::local("/home/me/notes", Platform::Unix).unwrap();
    assert!(matches!(local, Location::Local(_)));
    assert_eq!(
        Location::parse(&local.to_string(), Platform::Unix).unwrap(),
        local
    );
    assert!(matches!(
        Location::local(r"C:\notes", Platform::Windows),
        Ok(Location::Local(_))
    ));
    assert!(matches!(
        Location::local("host:notes", Platform::Unix),
        Err(LocationError::NotLocal(_))
    ));
    assert!(matches!(
        Location::local("", Platform::Unix),
        Err(LocationError::Empty)
    ));
}

// group: Location.deviceLabel

#[test]
fn device_label_is_the_peer_name_the_host_or_the_last_folder_segment() {
    assert_eq!(parse("/home/me/notes").device_label(), "notes");
    assert_eq!(parse("/home/me/notes/").device_label(), "notes");
    assert_eq!(parse("notes").device_label(), "notes");
    assert_eq!(parse("/").device_label(), "root");
    assert_eq!(parse("me@phone:/sdcard/notes").device_label(), "phone");
    assert_eq!(parse("ssh://phone:/sdcard/notes").device_label(), "phone");
    assert_eq!(
        parse("unix:///run/d.sock:/srv/notes").device_label(),
        "notes"
    );
    assert_eq!(
        parse("peer://my phone:/sdcard/notes").device_label(),
        "my phone"
    );
}

#[test]
fn a_peer_location_from_its_parts_is_the_one_parse_reads() {
    let phone = PeerName::parse("my phone").unwrap();
    let built = Location::peer(phone.clone(), "/sdcard/notes").unwrap();
    assert_eq!(
        built,
        Location::parse("peer://my phone:/sdcard/notes", Platform::Unix).unwrap()
    );
    assert!(matches!(
        Location::peer(phone.clone(), ""),
        Err(LocationError::EmptyPart { part: "path", .. })
    ));
    assert!(matches!(
        Location::peer(phone, "a\0b"),
        Err(LocationError::Nul(_))
    ));
}
