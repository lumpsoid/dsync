//! The command-line surface (SPEC §11.1, §11.2) as clap reads it: typed,
//! but not yet checked against each other. The cross-flag rules are
//! dsync-domain's ([`RunFlags::validate`]) or, for `agent`, [`AgentMode`]'s.

use std::net::IpAddr;

use clap::{Args, Parser, Subcommand};
use dsync_domain::host_port::parse_bind_address;
use dsync_domain::{DirPath, DirRule, Flags, StateDirChoice, Tuning};

use crate::failure::Failure;

#[derive(Parser, Debug)]
#[command(
    name = "dsync",
    about = "Bidirectional file sync between two replicas. See SPEC.md.",
    arg_required_else_help = true
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: CliCommand,
}

#[derive(Subcommand, Debug)]
pub enum CliCommand {
    /// Sync a profile, or an ad-hoc pair of locations (SPEC §11.1).
    Sync(SyncArgs),
    /// Scan, reconcile, and print the plan. Apply nothing.
    Status(StatusArgs),
    /// Serve replicas over the protocol (SPEC §4.2): over stdio (started by
    /// ssh on the remote host), on a unix socket, or to paired devices over
    /// the network (SPEC §4.4).
    Agent(AgentArgs),
    /// Pair devices for the authenticated network transport, and authorize
    /// a paired device for a replica root (SPEC §4.4).
    #[command(subcommand, arg_required_else_help = false)]
    Pair(PairCommand),
    /// Inspect and delete the per-replica archive logs this host keeps
    /// (SPEC §8).
    #[command(subcommand, arg_required_else_help = false)]
    Archive(ArchiveCommand),
}

/// `dsync pair …` (SPEC §4.4). Missing a subcommand is a usage error.
#[derive(Subcommand, Debug)]
pub enum PairCommand {
    /// Generate a pairing payload for this device and wait for one other
    /// device to redeem it (SPEC §4.4).
    Show(PairShowArgs),
    /// Accept a pairing payload from `dsync pair show` (SPEC §4.4) and
    /// record the enrolling device.
    Accept(PairAcceptArgs),
    /// List paired devices (SPEC §4.4).
    List(ListArgs),
    /// Remove a paired device from this host's own store (SPEC §4.4). Local
    /// only - the far end still trusts this host until it runs the same
    /// command.
    Revoke(PairRevokeArgs),
    /// Authorize a paired device to reach a replica root on this host
    /// (SPEC §4.4).
    Grant(PairGrantArgs),
    /// Re-issue this host's identity certificate under its existing key
    /// (SPEC §4.4). The device id does not change; paired devices keep
    /// their pairing.
    Renew(StateDirArgs),
}

#[derive(Args, Debug)]
pub struct PairShowArgs {
    /// This host's own label for the device that redeems this payload
    /// (SPEC §4.4) - local, like a `~/.ssh/config` Host alias, and what
    /// `dsync pair grant` and `peer://` address it by. Required.
    #[arg(long, value_name = "NAME")]
    pub name: String,
    /// The port this device's `dsync agent --serve` listens on. Goes into
    /// the payload as the address the paired device dials from then on, so
    /// give it here if --serve runs on a non-default port.
    #[arg(
        long,
        value_name = "PORT",
        default_value_t = Tuning::DEFAULT.peer_port,
        value_parser = clap::value_parser!(u16).range(1..)
    )]
    pub serve_port: u16,
    /// The address the pairing endpoint binds. Defaults to 0.0.0.0, every
    /// IPv4 interface; :: for a dual-stack socket; or one interface's own
    /// address to answer only there - which is then what the payload
    /// advertises, unless --advertise says otherwise. An address literal,
    /// not a hostname; if it cannot be bound, this fails rather than
    /// falling back.
    #[arg(long, value_name = "ADDRESS")]
    pub bind: Option<String>,
    /// The address the payload tells the other device to dial. Defaults to
    /// --bind's when that named one interface, and otherwise to the first
    /// non-loopback address this machine has - a guess, and the wrong one
    /// on a host with a VPN up or a second NIC. An address literal.
    #[arg(long, value_name = "ADDRESS")]
    pub advertise: Option<String>,
    #[command(flatten)]
    pub state: StateDirArgs,
}

impl PairShowArgs {
    /// `--bind`, or every IPv4 interface: `::` fails outright where IPv6
    /// is disabled, so it is opt-in.
    pub fn bind(&self) -> Result<IpAddr, Failure> {
        match &self.bind {
            None => Ok(IpAddr::from([0, 0, 0, 0])),
            Some(text) => {
                parse_bind_address(text).map_err(|error| Failure::usage(format!("--bind: {error}")))
            }
        }
    }
}

#[derive(Args, Debug)]
pub struct PairAcceptArgs {
    /// The payload `dsync pair show` printed on the other device.
    #[arg(value_name = "PAYLOAD")]
    pub payload: String,
    /// This host's own label for the device being paired (SPEC §4.4) -
    /// local, like a `~/.ssh/config` Host alias. Required: naming is a
    /// deliberate operator choice. What the other device calls this one is
    /// its own choice, made by `dsync pair show --name` there.
    #[arg(long, value_name = "NAME")]
    pub name: String,
    /// The port this device's `dsync agent --serve` listens on. Sent to the
    /// device that showed the payload, which records this device at the
    /// address it connected from on this port and dials it there from then
    /// on, so give it here if --serve runs on a non-default port.
    #[arg(
        long,
        value_name = "PORT",
        default_value_t = Tuning::DEFAULT.peer_port,
        value_parser = clap::value_parser!(u16).range(1..)
    )]
    pub serve_port: u16,
    #[command(flatten)]
    pub state: StateDirArgs,
}

/// A listing: `pair list` and `archive list`.
#[derive(Args, Debug)]
pub struct ListArgs {
    /// Machine-readable output (JSON Lines) on stdout (SPEC §11.4).
    #[arg(long)]
    pub json: bool,
    #[command(flatten)]
    pub state: StateDirArgs,
}

#[derive(Args, Debug)]
pub struct PairRevokeArgs {
    /// The paired device's name (see `dsync pair list`).
    #[arg(value_name = "NAME")]
    pub name: String,
    #[command(flatten)]
    pub state: StateDirArgs,
}

#[derive(Args, Debug)]
pub struct PairGrantArgs {
    /// The paired device's name (see `dsync pair list`).
    #[arg(value_name = "NAME")]
    pub name: String,
    /// The replica root to authorize it for; a leading ~ expands against
    /// this host's home, as a peer's requested root does.
    #[arg(value_name = "PATH")]
    pub path: String,
    #[command(flatten)]
    pub state: StateDirArgs,
}

/// `dsync archive …` (SPEC §8). Missing a subcommand is a usage error.
#[derive(Subcommand, Debug)]
pub enum ArchiveCommand {
    /// List the archive logs this host keeps, and what they cost on disk.
    List(ListArgs),
    /// Delete a profile's archive logs (or --all of them). The next run
    /// rescans from scratch; no replica file is touched.
    Clear(ArchiveClearArgs),
}

#[derive(Args, Debug)]
pub struct ArchiveClearArgs {
    /// The profile: its name, or the id `dsync archive list` prints.
    #[arg(value_name = "PROFILE", required_unless_present = "all")]
    pub profile: Option<String>,
    /// Every archive on this host, rather than one profile's.
    #[arg(long, conflicts_with = "profile")]
    pub all: bool,
    #[command(flatten)]
    pub state: StateDirArgs,
}

/// What `archive clear` deletes.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ClearTarget {
    All,
    /// A profile name, or an id as `archive list` prints it.
    Profile(String),
}

impl ArchiveClearArgs {
    /// clap has already refused both, and neither.
    pub fn target(&self) -> Result<ClearTarget, Failure> {
        match (&self.profile, self.all) {
            (None, true) => Ok(ClearTarget::All),
            (Some(profile), false) => Ok(ClearTarget::Profile(profile.clone())),
            _ => Err(Failure::usage(
                "dsync archive clear takes either a profile or --all, not both.",
            )),
        }
    }
}

#[derive(Args, Debug)]
pub struct SyncArgs {
    /// A profile name, or two locations.
    #[arg(value_name = "PROFILE | LOCATION_A LOCATION_B")]
    pub target: Vec<String>,
    /// Show the plan, apply nothing.
    #[arg(long)]
    pub dry_run: bool,
    #[command(flatten)]
    pub run: RunArgs,
}

/// `status` is `sync --dry-run` under a friendlier name, so it has no
/// `--dry-run` of its own: passing one is an unknown flag, not a no-op.
#[derive(Args, Debug)]
pub struct StatusArgs {
    /// The profile name.
    #[arg(value_name = "PROFILE")]
    pub target: Vec<String>,
    #[command(flatten)]
    pub run: RunArgs,
}

/// The flags `sync` and `status` share (SPEC §11.2).
#[derive(Args, Debug)]
pub struct RunArgs {
    /// Apply non-conflicting actions without asking; conflicts are listed,
    /// not resolved.
    #[arg(long)]
    pub batch: bool,
    /// Apply deletions that remove over half of a side's files (10 or more)
    /// without asking; without it, --batch refuses such a run (SPEC §10).
    #[arg(long)]
    pub allow_mass_delete: bool,
    /// Machine-readable output (JSON Lines) on stdout.
    #[arg(long)]
    pub json: bool,
    /// Glob to ignore, additive to the profile. Repeatable.
    #[arg(long, value_name = "GLOB")]
    pub ignore: Vec<String>,
    /// Size in bytes to warn above.
    #[arg(long, value_name = "BYTES", allow_negative_numbers = true)]
    pub warn_size: Option<i64>,
    /// Hash parallelism.
    #[arg(long, value_name = "N", allow_negative_numbers = true)]
    pub jobs: Option<i64>,
    /// Benchmarks only: how many apply actions overlap.
    #[arg(long, value_name = "N", hide = true, allow_negative_numbers = true)]
    pub apply_concurrency: Option<i64>,
    /// One option for ssh itself, before the destination, e.g.
    /// --ssh-option=-p --ssh-option=2222. Repeatable, one argv word each.
    /// Additive to the profile's [ssh.a]/[ssh.b]; applies to every remote
    /// replica of this run reached over ssh.
    #[arg(long, value_name = "ARG", allow_hyphen_values = true)]
    pub ssh_option: Vec<String>,
    /// The command that starts the agent on the far side. Default: "dsync",
    /// resolved on the remote non-interactive PATH.
    #[arg(long, value_name = "CMD", allow_hyphen_values = true)]
    pub remote_dsync: Option<String>,
    /// Print where the run spent its time, and what it asked of each
    /// replica, after the summary (SPEC §17).
    #[arg(long)]
    pub timings: bool,
    /// Print more detail.
    #[arg(long)]
    pub verbose: bool,
    /// Print only the summary line and errors.
    #[arg(long)]
    pub quiet: bool,
}

impl RunArgs {
    /// The flags as dsync-domain validates them.
    pub fn into_flags(self, dry_run: bool) -> Flags {
        Flags {
            dry_run,
            batch: self.batch,
            json: self.json,
            timings: self.timings,
            verbose: self.verbose,
            quiet: self.quiet,
            ignore: self.ignore,
            warn_size: self.warn_size,
            default_warn_size_bytes: None,
            jobs: self.jobs,
            apply_concurrency: self.apply_concurrency,
            ssh_options: self.ssh_option,
            remote_dsync: self.remote_dsync,
            allow_mass_delete: self.allow_mass_delete,
            mass_delete: None,
        }
    }
}

/// `--state-dir` (SPEC §11.2): on `agent`, and on every `pair` and
/// `archive` subcommand; never on `sync`/`status` (SPEC §8.3).
#[derive(Args, Debug)]
pub struct StateDirArgs {
    /// Keep this invocation's state here - archive logs and their locks,
    /// this device's identity, the paired-device store - instead of the
    /// platform default (SPEC §8.3). Used verbatim, created if missing.
    /// Two agents on one host need different ones.
    #[arg(long, value_name = "PATH")]
    pub state_dir: Option<String>,
}

impl StateDirArgs {
    pub fn choice(&self) -> Result<StateDirChoice, Failure> {
        match &self.state_dir {
            None => Ok(StateDirChoice::Rule(DirRule::HOST)),
            Some(path) => DirPath::parse(path)
                .map(StateDirChoice::Explicit)
                .map_err(|_| {
                    Failure::usage(
                        "--state-dir needs a path. An empty one would put this host's archive \
                     logs, locks and paired-device store in whatever directory this process \
                     was started in.",
                    )
                }),
        }
    }
}

#[derive(Args, Debug)]
pub struct AgentArgs {
    /// Speak the protocol over stdin/stdout, for one replica, until stdin
    /// closes. What ssh starts on the remote host.
    #[arg(long)]
    pub stdio: bool,
    /// Bind that unix socket and serve every connection on it until this
    /// process is signalled. Reached with a "unix://<socket>:<path>"
    /// location. Anyone who can open the socket gets unauthenticated
    /// access to the replicas served through it, so put it in a directory
    /// only you can enter, such as $XDG_RUNTIME_DIR.
    #[arg(long, value_name = "SOCKET")]
    pub listen: Option<String>,
    /// Serve paired devices over the network until this process is
    /// signalled (SPEC §4.4). Only a device in `dsync pair list` can
    /// connect, and only to the roots `dsync pair grant` gave it.
    #[arg(long)]
    pub serve: bool,
    /// The port --serve binds (default 28771); a second agent on the same
    /// host needs a different one.
    #[arg(long, value_name = "PORT")]
    pub port: Option<u16>,
    /// The address --serve binds. Defaults to 0.0.0.0, every IPv4
    /// interface; :: for a dual-stack socket. An address literal, not a
    /// hostname; if it cannot be bound, this fails rather than falling back.
    #[arg(long, value_name = "ADDRESS")]
    pub bind: Option<String>,
    #[command(flatten)]
    pub state: StateDirArgs,
}

/// The one transport an agent serves (SPEC §11.1): none is a default and
/// two are not a precedence rule, so both are usage errors.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum AgentMode {
    Stdio,
    Listen(String),
    Serve { bind: IpAddr, port: u16 },
}

impl AgentArgs {
    pub fn mode(&self) -> Result<AgentMode, Failure> {
        let mut named = Vec::new();
        if self.stdio {
            named.push("--stdio");
        }
        if self.listen.is_some() {
            named.push("--listen");
        }
        if self.serve {
            named.push("--serve");
        }
        if named.len() > 1 {
            return Err(Failure::usage(format!(
                "dsync agent takes one transport, not {}: --stdio serves a single session \
                 over this process's stdio, --listen and --serve each outlive any number of \
                 sessions, and only --serve authenticates who connects.",
                named.join(" and ")
            )));
        }
        if self.port.is_some() && !self.serve {
            return Err(Failure::usage("--port only means something with --serve."));
        }
        if self.bind.is_some() && !self.serve {
            return Err(Failure::usage(
                "--bind only means something with --serve: --listen binds a unix socket, \
                 which has a path rather than an address, and --stdio binds nothing at all.",
            ));
        }
        if self.stdio {
            return Ok(AgentMode::Stdio);
        }
        if let Some(socket) = &self.listen {
            if socket.is_empty() {
                return Err(Failure::usage("--listen needs a socket path."));
            }
            return Ok(AgentMode::Listen(socket.clone()));
        }
        if self.serve {
            let bind = match &self.bind {
                None => IpAddr::from([0, 0, 0, 0]),
                Some(text) => parse_bind_address(text)
                    .map_err(|error| Failure::usage(format!("--bind: {error}")))?,
            };
            return Ok(AgentMode::Serve {
                bind,
                port: self.port.unwrap_or(Tuning::DEFAULT.peer_port),
            });
        }
        Err(Failure::usage(
            "dsync agent needs a transport: --stdio (what ssh starts), --listen <socket path>, \
             or --serve.",
        ))
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;

    fn parse(argv: &[&str]) -> Result<Cli, clap::Error> {
        Cli::try_parse_from(std::iter::once("dsync").chain(argv.iter().copied()))
    }

    fn agent(argv: &[&str]) -> Result<AgentMode, Failure> {
        let mut full = vec!["agent"];
        full.extend_from_slice(argv);
        match parse(&full).expect("agent flags parse").command {
            CliCommand::Agent(args) => args.mode(),
            other => panic!("not agent: {other:?}"),
        }
    }

    fn usage_text(failure: Failure) -> String {
        match failure {
            Failure::Usage(message) => message,
            other => panic!("not a usage error: {other:?}"),
        }
    }

    #[test]
    fn sync_takes_one_profile_or_two_locations_and_every_common_flag() {
        let Ok(Cli {
            command: CliCommand::Sync(args),
        }) = parse(&[
            "sync",
            "/a",
            "/b",
            "--batch",
            "--json",
            "--ignore",
            "*.tmp",
            "--ignore=build",
            "--warn-size",
            "10",
            "--jobs",
            "2",
            "--apply-concurrency",
            "4",
            "--ssh-option=-p",
            "--ssh-option",
            "-i",
            "--remote-dsync",
            "/opt/dsync",
            "--timings",
            "--verbose",
            "--allow-mass-delete",
        ])
        else {
            panic!("sync did not parse");
        };
        assert_eq!(args.target, ["/a", "/b"]);
        let flags = args.run.into_flags(args.dry_run);
        assert_eq!(
            flags,
            Flags {
                dry_run: false,
                batch: true,
                json: true,
                timings: true,
                verbose: true,
                quiet: false,
                ignore: vec!["*.tmp".into(), "build".into()],
                warn_size: Some(10),
                default_warn_size_bytes: None,
                jobs: Some(2),
                apply_concurrency: Some(4),
                ssh_options: vec!["-p".into(), "-i".into()],
                remote_dsync: Some("/opt/dsync".into()),
                allow_mass_delete: true,
                mass_delete: None,
            }
        );
    }

    #[test]
    fn negative_numbers_reach_validation_rather_than_reading_as_flags() {
        let Ok(Cli {
            command: CliCommand::Sync(args),
        }) = parse(&["sync", "p", "--warn-size", "-1", "--jobs", "-3"])
        else {
            panic!("sync did not parse");
        };
        assert_eq!(args.run.warn_size, Some(-1));
        assert_eq!(args.run.jobs, Some(-3));
    }

    #[test]
    fn a_non_integer_flag_value_is_a_parse_error() {
        assert!(parse(&["sync", "p", "--jobs", "two"]).is_err());
        assert!(parse(&["sync", "p", "--warn-size", "1.5"]).is_err());
        assert!(parse(&["sync", "p", "--apply-concurrency", "x"]).is_err());
    }

    #[test]
    fn status_has_no_dry_run_flag() {
        assert!(parse(&["status", "p", "--dry-run"]).is_err());
        assert!(parse(&["status", "p", "--json"]).is_ok());
    }

    #[test]
    fn state_dir_is_not_a_sync_or_status_flag() {
        assert!(parse(&["sync", "p", "--state-dir", "/s"]).is_err());
        assert!(parse(&["status", "p", "--state-dir", "/s"]).is_err());
    }

    #[test]
    fn an_empty_state_dir_is_refused_and_a_given_one_is_used_verbatim() {
        let args = |state_dir: Option<&str>| StateDirArgs {
            state_dir: state_dir.map(str::to_owned),
        };
        assert!(args(Some("")).choice().is_err());
        assert_eq!(
            args(Some("/srv/dsync")).choice().unwrap(),
            StateDirChoice::Explicit(DirPath::parse("/srv/dsync").unwrap())
        );
        assert_eq!(
            args(None).choice().unwrap(),
            StateDirChoice::Rule(DirRule::HOST)
        );
    }

    #[test]
    fn agent_needs_exactly_one_transport() {
        assert!(usage_text(agent(&[]).unwrap_err()).contains("needs a transport"));
        let two = usage_text(agent(&["--stdio", "--listen", "/s"]).unwrap_err());
        assert!(two.contains("--stdio and --listen"), "{two}");
        assert!(agent(&["--serve", "--stdio"]).is_err());
        assert!(agent(&["--serve", "--listen", "/s"]).is_err());
        assert_eq!(agent(&["--stdio"]).unwrap(), AgentMode::Stdio);
        assert_eq!(
            agent(&["--listen", "/run/a.sock"]).unwrap(),
            AgentMode::Listen("/run/a.sock".into())
        );
    }

    #[test]
    fn port_and_bind_only_mean_something_with_serve() {
        assert!(usage_text(agent(&["--stdio", "--port", "9"]).unwrap_err()).contains("--port"));
        assert!(
            usage_text(agent(&["--listen", "/s", "--bind", "::"]).unwrap_err()).contains("--bind")
        );
    }

    #[test]
    fn serve_defaults_to_every_ipv4_interface_on_the_peer_port() {
        assert_eq!(
            agent(&["--serve"]).unwrap(),
            AgentMode::Serve {
                bind: IpAddr::from([0, 0, 0, 0]),
                port: Tuning::DEFAULT.peer_port
            }
        );
        assert_eq!(
            agent(&["--serve", "--bind", "[::1]", "--port", "0"]).unwrap(),
            AgentMode::Serve {
                bind: "::1".parse().unwrap(),
                port: 0
            }
        );
    }

    #[test]
    fn a_bind_that_is_not_an_address_literal_is_named() {
        let message = usage_text(agent(&["--serve", "--bind", "example.com"]).unwrap_err());
        assert!(message.contains("example.com"), "{message}");
    }

    #[test]
    fn a_port_that_is_not_a_port_is_a_parse_error() {
        assert!(parse(&["agent", "--serve", "--port", "70000"]).is_err());
        assert!(parse(&["agent", "--serve", "--port", "http"]).is_err());
    }

    #[test]
    fn an_unrecognized_flag_is_a_parse_error() {
        assert!(parse(&["agent", "--stdio", "--frobnicate"]).is_err());
    }

    #[test]
    fn every_pair_and_archive_subcommand_takes_state_dir() {
        let commands: &[&[&str]] = &[
            &["pair", "show", "--name", "phone"],
            &["pair", "accept", "--name", "desktop", "code"],
            &["pair", "list"],
            &["pair", "revoke", "phone"],
            &["pair", "grant", "phone", "/n"],
            &["pair", "renew"],
            &["archive", "list"],
            &["archive", "clear", "--all"],
        ];
        for command in commands {
            let mut argv = command.to_vec();
            argv.extend(["--state-dir", "/srv/dsync"]);
            assert!(parse(&argv).is_ok(), "{argv:?}");
        }
    }

    #[test]
    fn a_pair_or_archive_with_no_subcommand_is_an_error_not_help() {
        for argv in [&["pair"][..], &["archive"]] {
            let kind = parse(argv).unwrap_err().kind();
            assert_eq!(kind, clap::error::ErrorKind::MissingSubcommand, "{argv:?}");
        }
    }

    #[test]
    fn show_defaults_to_every_ipv4_interface_and_the_peer_port() {
        let Ok(Cli {
            command: CliCommand::Pair(PairCommand::Show(args)),
        }) = parse(&["pair", "show", "--name", "phone"])
        else {
            panic!("show did not parse");
        };
        assert_eq!(args.bind().unwrap(), IpAddr::from([0, 0, 0, 0]));
        assert_eq!(args.serve_port, Tuning::DEFAULT.peer_port);
        assert!(parse(&["pair", "show", "--name", "p", "--serve-port", "0"]).is_err());
    }

    #[test]
    fn archive_clear_takes_a_profile_or_all() {
        let target = |argv: &[&str]| match parse(argv).expect("parses").command {
            CliCommand::Archive(ArchiveCommand::Clear(args)) => args.target().unwrap(),
            other => panic!("not clear: {other:?}"),
        };
        assert_eq!(target(&["archive", "clear", "--all"]), ClearTarget::All);
        assert_eq!(
            target(&["archive", "clear", "notes"]),
            ClearTarget::Profile("notes".into())
        );
        assert!(parse(&["archive", "clear"]).is_err());
        assert!(parse(&["archive", "clear", "notes", "--all"]).is_err());
    }

    #[test]
    fn an_unknown_command_or_a_lookalike_is_a_parse_error() {
        assert!(parse(&["frobnicate"]).is_err());
        assert!(parse(&["remote-agent", "--stdio"]).is_err());
    }
}
