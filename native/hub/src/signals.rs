//! The signals between the Flutter head and the Rust core. `rinf gen`
//! turns these (and the views in views.rs) into Dart classes under
//! lib/app/rust/bindings; only lib/app/core_link reads them.
//!
//! Request/response over rinf's one-way signals: Dart sends a
//! [`CoreRequest`] carrying a fresh `u64` id, and the hub answers it with
//! exactly one [`CoreReply`] carrying the same id. A command that starts a
//! session (a run, serving, a pairing window) takes its request id as the
//! session id: Dart can listen for the session's stream before the reply
//! lands, so no update is lost to the race.
//!
//! Streams are plain Rust->Dart signals tagged with their session: a run's
//! [`RunUpdate`]s, serving's [`ServeUpdate`]s, a pairing window's
//! [`EnrolmentUpdate`]s. Each ends with one terminal update; nothing for
//! that session follows it.

use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

use crate::views::{
    ActionView, AddressesView, ArchiveView, ConflictView, DeviceView, DirsView, EnrolmentEndView,
    FilterPreviewView, FilterRowView, IdentityView, PairCodeView, PairingShownView,
    PeerContactView, ProbeOutcome, ProfileEntry, ReplicaInfoView, ResultView, RunEndView,
    RunErrorView, RunStartedView, ScanProbeView, ServeStartedView, SideView, SkippedView,
    SummaryView, TallyView,
};

/// Dart asks the core for one thing. Answered by one [`CoreReply`] with
/// the same `id`.
#[derive(Deserialize, DartSignal)]
pub struct CoreRequest {
    pub id: u64,
    pub command: CoreCommand,
}

/// Every command the head sends, by intent. Device ids travel as their
/// text form; paths as the head holds them.
#[derive(Deserialize, SignalPiece)]
pub enum CoreCommand {
    /// Must come first. `support_dir` is the app's own support directory
    /// on Android and iOS (the `dsync-rs` leaf is appended to it); on the
    /// desktop it is absent and the directories resolve as the CLI's do.
    /// `device_name` names an identity created on this device.
    Init {
        support_dir: Option<String>,
        device_name: String,
    },

    /// This device's identity, created on first use.
    ShowIdentity,
    /// The same key, a fresh certificate (`dsync pair renew`).
    RenewIdentity {
        common_name: Option<String>,
    },

    /// Opens a pairing window: session id = request id. Whoever redeems
    /// the payload is recorded as `name`; `bind` is an address literal;
    /// `advertise` overrides the host the payload names.
    ShowPairing {
        name: String,
        bind: String,
        advertise: Option<String>,
        service_port: u16,
    },
    /// The operator's answer for the device waiting in `session`.
    ConfirmPairing {
        session: u64,
        accept: bool,
    },
    /// Closes the pairing window in `session`.
    CancelPairing {
        session: u64,
    },
    /// What a scanned or pasted pairing code says, before redeeming it.
    ReadPairCode {
        text: String,
    },
    /// Redeems a pairing code, recording the other device as `name`.
    AcceptPairing {
        code: String,
        name: String,
    },

    ListDevices,
    RenameDevice {
        device_id: String,
        name: String,
    },
    RevokeDevice {
        device_id: String,
    },
    /// `path` is expanded (`~`) before it is stored, as the listener
    /// expands a requested root before checking it.
    GrantRoot {
        device_id: String,
        path: String,
    },
    /// `root` exactly as the device's grant list holds it.
    WithdrawGrant {
        device_id: String,
        root: String,
    },
    /// Where to dial the device from now on (`host` or `host:port`): the
    /// field a connection records, written by hand or after a probe.
    SetDeviceAddress {
        device_id: String,
        address: String,
    },
    /// The operator compared the device's id with the one it shows itself,
    /// and they matched.
    VerifyDevice {
        device_id: String,
    },
    /// Takes that confirmation back.
    ClearVerification {
        device_id: String,
    },
    /// Whether the device answers and admits this host, at `address`
    /// (`host` or `host:port`) or where it was last reached.
    ProbePeer {
        device_id: String,
        address: Option<String>,
    },

    ListProfiles,
    /// Creates or overwrites the profile `name`.
    SaveProfile {
        name: String,
        draft: ProfileDraft,
    },
    RenameProfile {
        from: String,
        to: String,
    },
    DeleteProfile {
        name: String,
    },

    /// Starts a run: session id = request id. `address` overrides where
    /// the peer is dialled (`host` or `host:port`).
    StartRun {
        target: RunTarget,
        dry_run: bool,
        address: Option<String>,
    },
    /// The answer to the plan a run in `session` is waiting on.
    DecideRun {
        session: u64,
        decision: RunDecision,
    },
    /// The first stop is graceful; a second drops the run.
    StopRun {
        session: u64,
    },

    /// Serves paired devices on `bind:port`: session id = request id.
    StartServe {
        bind: String,
        port: u16,
    },
    StopServe {
        session: u64,
    },
    /// This machine's interface addresses and the best one to advertise.
    ServeAddresses,

    ListArchives,
    /// Deletes both sides' archives of `profile_id`.
    ClearArchive {
        profile_id: String,
    },

    /// The whole tree under `root` counted against `ignore`.
    PreviewFilters {
        root: String,
        ignore: Vec<String>,
    },
    /// One folder's rows (`None`: the root).
    ListFilterFolder {
        root: String,
        folder: Option<String>,
        ignore: Vec<String>,
    },
    /// Whether `pattern` is a valid ignore pattern (SPEC §9), before any
    /// tree is read: `Done`, or `Failed` saying why not.
    CheckIgnorePattern {
        pattern: String,
    },
    /// Lists `path`, writes one entry and removes it (SPEC §3).
    CheckFolder {
        path: String,
    },
    /// Times the scan's layers over `root`, `passes` times.
    ProbeScan {
        root: String,
        ignore: Vec<String>,
        passes: u32,
    },
}

/// The head's profile: this device's `local_root` synced with
/// `remote_root` on the paired device `peer_device_id`.
#[derive(Deserialize, SignalPiece)]
pub struct ProfileDraft {
    pub local_root: String,
    pub peer_device_id: String,
    pub remote_root: String,
    pub jobs: Option<u32>,
    pub ignore: Vec<String>,
}

/// What a run syncs: a saved profile, or a one-off pair.
#[derive(Deserialize, SignalPiece)]
pub enum RunTarget {
    Profile { name: String },
    Pair { draft: ProfileDraft },
}

/// The head's answer to a plan: which of its actions to keep (indices into
/// the plan's actions) and which conflicts to settle, and which way
/// (indices into its conflicts). A conflict left out stays unresolved.
#[derive(Deserialize, SignalPiece)]
pub struct RunDecision {
    pub keep: Vec<u32>,
    pub resolve: Vec<ConflictChoice>,
}

#[derive(Deserialize, SignalPiece)]
pub struct ConflictChoice {
    pub conflict: u32,
    pub keep: SideView,
}

/// The answer to the [`CoreRequest`] with the same `id`.
#[derive(Serialize, RustSignal)]
pub struct CoreReply {
    pub id: u64,
    pub result: ReplyResult,
}

/// What a command returned. `Failed` carries the core's own message.
#[derive(Serialize, SignalPiece)]
pub enum ReplyResult {
    Failed {
        message: String,
    },
    Done,
    /// `Init`'s answer: where the core keeps its state and config.
    Initialised(DirsView),
    Identity(IdentityView),
    PairingShown(PairingShownView),
    PairCode(PairCodeView),
    Device(DeviceView),
    Devices(Vec<DeviceView>),
    PeerProbed(ProbeOutcome),
    Profiles(Vec<ProfileEntry>),
    RunStarted(RunStartedView),
    ServeStarted(ServeStartedView),
    Addresses(AddressesView),
    Archives(Vec<ArchiveView>),
    FilterPreview(FilterPreviewView),
    FilterFolder(Vec<FilterRowView>),
    /// `None`: the folder is usable.
    FolderChecked {
        refusal: Option<String>,
    },
    ScanProbe(ScanProbeView),
}

/// One step of the run in `session`.
#[derive(Serialize, RustSignal)]
pub struct RunUpdate {
    pub session: u64,
    pub update: RunUpdateBody,
}

/// SPEC §11.4's events, as the head shows them. The per-action ones
/// (approved actions, results, progress) arrive as [`RunUpdateBody::Applied`]
/// batches, at most one per 50 ms; every other update flushes the batch
/// before it, so the order is the run's.
#[derive(Serialize, SignalPiece)]
pub enum RunUpdateBody {
    /// Both sides are connected; what dialling each `peer://` side learned.
    Connected {
        peers: Vec<PeerContactView>,
    },
    Replicas {
        a: ReplicaInfoView,
        b: ReplicaInfoView,
        last_run_unfinished: bool,
    },
    ScanTally {
        a: TallyView,
        b: TallyView,
    },
    Skipped(SkippedView),
    Conflict(ConflictView),
    /// The plan. `awaiting_decision`: the run now waits for a
    /// `DecideRun` (a dry run does not).
    Plan {
        actions: Vec<ActionView>,
        conflicts: Vec<ConflictView>,
        bytes_to_transfer: u64,
        exceeds_warn_size: bool,
        awaiting_decision: bool,
    },
    Applied {
        approved: Vec<ActionView>,
        results: Vec<ResultView>,
        /// The latest progress in the batch: completed of total.
        progress: Option<ProgressView>,
    },
    Summary(SummaryView),
    Error(RunErrorView),
    /// Terminal.
    Ended(RunEndView),
}

#[derive(Serialize, SignalPiece)]
pub struct ProgressView {
    pub completed: u64,
    pub total: u64,
}

/// One connection's story on the serving session `session`.
#[derive(Serialize, RustSignal)]
pub struct ServeUpdate {
    pub session: u64,
    pub update: ServeUpdateBody,
}

#[derive(Serialize, SignalPiece)]
pub enum ServeUpdateBody {
    Refused {
        from: String,
        message: String,
    },
    Started {
        from: String,
        device_id: String,
        name: String,
    },
    /// A session opened the replica at `root` (expanded).
    Serving {
        root: String,
    },
    Ended {
        from: String,
        device_id: String,
        name: String,
        failure: Option<String>,
    },
    /// Terminal: stopped, or the listener failed.
    Stopped {
        failure: Option<String>,
    },
}

/// The pairing window `session`.
#[derive(Serialize, RustSignal)]
pub struct EnrolmentUpdate {
    pub session: u64,
    pub update: EnrolmentUpdateBody,
}

#[derive(Serialize, SignalPiece)]
pub enum EnrolmentUpdateBody {
    /// A connection turned away before it redeemed the token.
    Refused { from: String, message: String },
    /// A device redeemed the payload; answer with `ConfirmPairing`. Its id
    /// is what the operator compares with the one it shows.
    Awaiting {
        from: String,
        device_id: String,
        name: String,
    },
    /// Terminal.
    Ended(EnrolmentEndView),
}
