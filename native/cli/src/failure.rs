//! Why a command stopped before it could produce a result of its own.
//! Both kinds are SPEC §11.5's exit 3; they differ only in what is printed.

use std::fmt;
use std::io::Write;

/// Exit 3: bad arguments, or a fatal failure before or outside a run.
#[derive(Debug)]
pub enum Failure {
    /// The arguments were refused: the message, then a pointer to `--help`.
    Usage(String),
    /// Anything else, printed as it stands.
    Fatal(String),
}

impl Failure {
    pub const EXIT_CODE: u8 = 3;

    pub fn usage(message: impl Into<String>) -> Failure {
        Failure::Usage(message.into())
    }

    /// `error: <cause>`.
    pub fn error(cause: impl fmt::Display) -> Failure {
        Failure::Fatal(format!("error: {cause}"))
    }

    /// Prints this to `err` (stderr) and returns the exit code.
    pub fn report(&self, err: &mut impl Write) -> u8 {
        let _ = match self {
            Failure::Usage(message) => writeln!(
                err,
                "error: {message}\n\nRun `dsync <command> --help` for usage."
            ),
            Failure::Fatal(message) => writeln!(err, "{message}"),
        };
        Failure::EXIT_CODE
    }
}
