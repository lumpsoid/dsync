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
//! Streams are plain Rust->Dart signals tagged with their session. A run
//! sends [`RunSnapshot`]s: the whole view after every change, so the head
//! renders the latest and decides nothing; what the user does goes back as
//! a [`RunIntent`] in [`CoreCommand::SteerRun`]. Serving sends
//! [`ServeSnapshot`]s and a pairing window [`PairingSnapshot`]s the same
//! way. Every snapshot says whether it is its session's `last`: the head
//! closes the session's stream on it and asks nothing of its own.

use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

use crate::views::{
    ActionChoiceView, AddressesView, ArchiveView, ConflictChoiceView, DeviceView, DirsView,
    FilterPreviewView, FilterRowView, IdentityView, PairCodeView, PairingView, ProbeOutcome,
    ProfileEntry, RootKindView, RunView, ScanProbeView, ServeStartedView, ServeView,
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
    /// on Android and iOS (the `dsync` leaf is appended to it); on the
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

    /// Opens a pairing window: session id = request id, answered `Done`
    /// once it is open; the payload is the session's first snapshot.
    /// Whoever redeems it is recorded as `name`; `bind` is an address
    /// literal; `advertise` overrides the host the payload names.
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
    /// the peer is dialled (`host` or `host:port`). Answered `Done` at
    /// once; everything after, a target that will not resolve included,
    /// is the session's [`RunSnapshot`]s.
    StartRun {
        target: RunTarget,
        dry_run: bool,
        address: Option<String>,
    },
    /// What the user did to the run in `session`.
    SteerRun {
        session: u64,
        intent: RunIntent,
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
    /// Deletes both sides' archives of the entry `entry_id`.
    ClearArchive {
        entry_id: String,
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
    /// Whether `path` can be a root of `kind` (SPEC §3): a folder is
    /// listed, one entry written in it and removed; a file's folder is so
    /// probed, and the file opened for reading if it is there.
    CheckFolder {
        path: String,
        kind: RootKindView,
    },
    /// Times the scan's layers over `root`, `passes` times.
    ProbeScan {
        root: String,
        ignore: Vec<String>,
        passes: u32,
    },
}

/// The head's profile: each entry's `local_root` on this device synced
/// with its `remote_root` on the paired device `peer_device_id`.
#[derive(Clone, Deserialize, SignalPiece)]
pub struct ProfileDraft {
    pub peer_device_id: String,
    pub entries: Vec<EntryDraft>,
    pub jobs: Option<u32>,
    pub ignore: Vec<String>,
}

/// One entry of a [`ProfileDraft`]: two folders, or one file each.
#[derive(Clone, Deserialize, SignalPiece)]
pub struct EntryDraft {
    pub kind: RootKindView,
    pub local_root: String,
    pub remote_root: String,
}

/// What a run syncs: a saved profile, or a one-off pair.
#[derive(Clone, Deserialize, SignalPiece)]
pub enum RunTarget {
    Profile { name: String },
    Pair { draft: ProfileDraft },
}

/// What the user did to a run. The run holds the review's choices and
/// decides what each intent means where it stands: one it cannot take -
/// a choice the row does not offer, an answer nobody asked for, a resume
/// of a live run - changes nothing.
#[derive(Deserialize, SignalPiece)]
pub enum RunIntent {
    /// The planned action at `index` under review.
    ChooseAction {
        index: u32,
        choice: ActionChoiceView,
    },
    /// The conflict at `index` under review.
    ChooseConflict {
        index: u32,
        choice: ConflictChoiceView,
    },
    /// Answers the review with the choices made.
    Confirm,
    /// Answers the review with the plan unchanged and every conflict left
    /// open (`--batch`), whatever was chosen.
    AcceptAll,
    /// SPEC §10's delete guard: apply the deletions, or apply nothing.
    AnswerDeletes { proceed: bool },
    /// The user's stop: graceful - nothing further starts, what is in
    /// flight finishes.
    Stop,
    /// The app went to the background: a live run is suspended as
    /// paused.
    Pause,
    /// Runs the target again after a pause, a failure or a busy replica.
    Resume,
    /// The app came back: a paused run resumes.
    Foreground,
    /// The page left: a live run is stopped (dropped, when already
    /// stopping), and the session ends.
    Close,
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
    PairCode(PairCodeView),
    Device(DeviceView),
    Devices(Vec<DeviceView>),
    PeerProbed(ProbeOutcome),
    Profiles(Vec<ProfileEntry>),
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

/// The run in `session`, whole, as it now stands. `last`: the session is
/// over - finished, stopped, or the page left - and sends nothing more.
#[derive(Serialize, RustSignal)]
pub struct RunSnapshot {
    pub session: u64,
    pub view: RunView,
    pub last: bool,
}

/// The serving session `session`, whole, as it now stands. `last`: it no
/// longer answers, stopped or failed, and sends nothing more.
#[derive(Serialize, RustSignal)]
pub struct ServeSnapshot {
    pub session: u64,
    pub view: ServeView,
    pub last: bool,
}

/// The pairing window `session`, whole, as it now stands. `last`: the
/// window closed, and the view says how.
#[derive(Serialize, RustSignal)]
pub struct PairingSnapshot {
    pub session: u64,
    pub view: PairingView,
    pub last: bool,
}
