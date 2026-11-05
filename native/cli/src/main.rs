//! `dsync`: the command line (SPEC §11). `main` reads the host's facts
//! once, parses argv, runs the command on a tokio runtime and exits with
//! SPEC §11.5's code. See SPEC.md §11 and §13.

mod agent;
mod archive;
mod args;
mod failure;
mod host;
mod interactive;
mod log;
mod pair;
mod qr;
mod render;
mod stop;
mod sync;

use std::io::{self, Write};

use clap::Parser;
use clap::error::ErrorKind;
use dsync_domain::{Command, SpoolSetting};

use crate::args::{Cli, CliCommand};
use crate::failure::Failure;
use crate::host::Host;

fn main() {
    // Before the runtime starts any thread: see `Host::read`.
    let code = match Host::read() {
        Ok(host) => match Cli::try_parse() {
            Ok(cli) => run(cli, &host),
            Err(error) => parse_failure(&error),
        },
        Err(failure) => failure.report(&mut io::stderr()),
    };
    let _ = io::stdout().flush();
    std::process::exit(i32::from(code));
}

fn run(cli: Cli, host: &Host) -> u8 {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            return Failure::error(format!("cannot start the runtime: {error}"))
                .report(&mut io::stderr());
        }
    };
    let result = runtime.block_on(async {
        match cli.command {
            CliCommand::Sync(args) => {
                let spool = args.spool();
                let flags = args.run.into_flags(args.dry_run);
                sync::sync(Command::Sync, &args.target, flags, spool, host).await
            }
            CliCommand::Status(args) => {
                let flags = args.run.into_flags(false);
                // A dry run writes nothing, so it has nothing to spool.
                sync::sync(
                    Command::Status,
                    &args.target,
                    flags,
                    SpoolSetting::Off,
                    host,
                )
                .await
            }
            CliCommand::Agent(args) => agent::agent(args, host).await,
            CliCommand::Pair(command) => pair::pair(command, host).await,
            CliCommand::Archive(command) => archive::archive(command, host),
            CliCommand::Log(args) => log::log(&args, host),
        }
    });
    // Not a graceful drop: a blocking read of stdin, or a session still
    // winding down after a signal, is not waited for.
    runtime.shutdown_background();
    result.unwrap_or_else(|failure| failure.report(&mut io::stderr()))
}

/// `--help` and a bare `dsync` print usage and succeed; every other
/// argument error is SPEC §11.5's exit 3, not clap's 2.
fn parse_failure(error: &clap::Error) -> u8 {
    match error.kind() {
        ErrorKind::DisplayHelp
        | ErrorKind::DisplayVersion
        | ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand => {
            let _ = write!(io::stdout(), "{}", error.render());
            0
        }
        _ => {
            let _ = write!(io::stderr(), "{}", error.render());
            Failure::EXIT_CODE
        }
    }
}

#[cfg(test)]
mod test_support {
    use std::future::Future;
    use std::time::Duration;

    /// Runs `work` under a deadline, failing the test by name past it.
    pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
        tokio::time::timeout(Duration::from_secs(5), work)
            .await
            .unwrap_or_else(|_| panic!("{label} did not finish within its deadline"))
    }
}
