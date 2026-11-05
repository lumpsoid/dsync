//! Whether a local replica spools a run's downloads to app-private storage
//! before landing them (SPEC §4.2's `stage`), chosen by whoever opens it.

/// `Off`: a `stage` is refused, and every download is a `write`. `On`: a
/// body is taken into the spool and landed behind it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SpoolSetting {
    Off,
    On,
}
