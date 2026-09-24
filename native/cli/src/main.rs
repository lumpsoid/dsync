//! `dsync-rs`: the Rust core's CLI head (task 07876c spike). See
//! native/NOTES.md.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::Context;
use clap::{Parser, Subcommand};
use dsync_core::client::{PushOptions, push};
use dsync_core::identity::Identity;
use dsync_core::order::Order;
use dsync_core::peer_pin::PeerPin;
use dsync_core::server::{ServeEvent, ServeOptions, serve};
use dsync_core::slow_create;
use tokio::sync::mpsc;

#[derive(Parser)]
#[command(
    name = "dsync-rs",
    about = "One-way tree transfer over pinned mutual TLS"
)]
struct Cli {
    /// Directory holding this device's identity (cert.pem, key.pem);
    /// created with a new identity if absent. Default: $XDG_CONFIG_HOME
    /// (or ~/.config)/dsync-rs.
    #[arg(long, global = true)]
    identity: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print this device's id, creating its identity first if need be.
    Id,
    /// Receive one tree into a directory, from one admitted peer.
    Serve {
        #[arg(long)]
        root: PathBuf,
        #[arg(long, default_value_t = 47670)]
        port: u16,
        /// The peer's device id, or ANY.
        #[arg(long)]
        allow: PeerPin,
        /// Blocking file-writer threads.
        #[arg(long, default_value_t = 16)]
        writers: usize,
        /// Print a line per file written.
        #[arg(long)]
        verbose: bool,
        /// TEST ONLY: make every file create sleep this long, one create at
        /// a time per folder, as Android's FUSE storage does
        /// (core/src/slow_create.rs). 0 is off.
        #[arg(long, default_value_t = 0, hide = true)]
        simulate_create_ms: u64,
    },
    /// Send a directory's tree to a server.
    Push {
        dir: PathBuf,
        #[arg(long)]
        host: String,
        #[arg(long, default_value_t = 47670)]
        port: u16,
        /// The server's device id (ANY is accepted for testing).
        #[arg(long)]
        pin: PeerPin,
        /// The order files go out in: `walk` (path order) or `spread`
        /// (consecutive files from different folders).
        #[arg(long, default_value_t = Order::Spread)]
        order: Order,
    },
}

fn identity_dir(explicit: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    if let Some(dir) = explicit {
        return Ok(dir);
    }
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .context("no --identity, and neither XDG_CONFIG_HOME nor HOME is set")?;
    Ok(config.join("dsync-rs"))
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let identity = Identity::load_or_create(&identity_dir(cli.identity)?)?;
    let runtime = tokio::runtime::Runtime::new()?;
    match cli.command {
        Command::Id => println!("{}", identity.device_id()),
        Command::Serve {
            root,
            port,
            allow,
            writers,
            verbose,
            simulate_create_ms,
        } => {
            println!("id {}", identity.device_id());
            if simulate_create_ms > 0 {
                slow_create::set(Duration::from_millis(simulate_create_ms));
                println!("SIMULATING slow creates: {simulate_create_ms} ms, serialised per folder");
            }
            let (tx, mut rx) = mpsc::unbounded_channel();
            let printer = runtime.spawn(async move {
                let mut progress_events = 0u64;
                while let Some(event) = rx.recv().await {
                    match event {
                        ServeEvent::Ready { port, .. } => println!("listening on port {port}"),
                        ServeEvent::Connected { peer } => println!("peer {peer}"),
                        ServeEvent::FileDone { path, bytes } if verbose => {
                            println!("done {path} {bytes}")
                        }
                        ServeEvent::FileDone { .. } => {}
                        ServeEvent::Progress { .. } => progress_events += 1,
                    }
                }
                progress_events
            });
            let options = ServeOptions {
                root,
                port,
                allow,
                writers,
            };
            let served = runtime.block_on(serve(&identity, options, tx));
            let progress_events = runtime.block_on(printer)?;
            let received = served.context("serve failed")?;
            println!(
                "received {}  progress events {progress_events}",
                received.metrics
            );
            for line in received
                .writes
                .report(received.metrics.wall, received.metrics.cpu)
            {
                println!("{line}");
            }
        }
        Command::Push {
            dir,
            host,
            port,
            pin,
            order,
        } => {
            println!("id {}", identity.device_id());
            let report = runtime.block_on(push(
                &identity,
                PushOptions {
                    dir,
                    host,
                    port,
                    pin,
                    order,
                },
            ))?;
            println!("server {}", report.server);
            println!("sent {}  order {order}", report.metrics);
        }
    }
    Ok(())
}
