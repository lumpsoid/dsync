//! What scanning a tree costs on this device, split into the platform's
//! floor and dsync's own code (core's `ScanProbe`), plus whether the tree's
//! filesystem folds case (SPEC §16). A developer tool, not shipped: run it
//! over one entry's local root at a time. See README.md.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use dsync_core::{ScanProbe, probe_case_folding};
use dsync_domain::{Glob, Jobs, RuleSet};

#[derive(Parser)]
#[command(
    name = "dsync-scan-probe",
    about = "What scanning ROOT costs, layer by layer"
)]
struct Args {
    /// The tree to measure: one entry's local root.
    root: PathBuf,
    /// Walks back to back: a later pass much faster than the first says the
    /// cost is I/O and page cache.
    #[arg(long, default_value_t = 2)]
    passes: usize,
    /// Scan workers, as a run's `--jobs`.
    #[arg(long, default_value_t = i64::from(u16::from(Jobs::DEFAULT)))]
    jobs: i64,
    /// An ignore pattern, as the profile's; repeatable.
    #[arg(long)]
    ignore: Vec<String>,
}

fn main() -> ExitCode {
    match run(Args::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("dsync-scan-probe: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Args) -> Result<(), String> {
    let jobs = Jobs::new(args.jobs).map_err(|error| error.to_string())?;
    let ignore = args
        .ignore
        .iter()
        .map(|pattern| Glob::new(pattern).map_err(|error| error.to_string()))
        .collect::<Result<_, _>>()?;
    let rules = RuleSet::new(ignore, Vec::new());
    let folding = probe_case_folding(&args.root);
    println!("case folding: {folding:?}");
    let report = ScanProbe::new(jobs, folding)
        .run(&args.root, &rules, args.passes)
        .map_err(|error| error.to_string())?;
    print!("{report}");
    Ok(())
}
