//! A hub as the head drives it, without rinf: a [`Core`] over a temp
//! support directory (the mobile rule, so nothing touches this machine's
//! real state), commands in, replies and stream signals out.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::time::Duration;

use dsync_domain::{DIR_LEAF, Entry, HostFacts, Platform, Profile, ReplicaLocation};
use hub::signals::{CoreCommand, PairingSnapshot, ReplyResult, ServeSnapshot};
use hub::views::{
    ConflictRowView, EntryRunView, PairingView, PlanRowView, PlanUpdateView, PlanView,
    ReplicasView, RunPhaseView, RunStandingView, RunView, ServeView,
};
use hub::{Core, Outbox, Outgoing};
use tempfile::TempDir;
use tokio::sync::mpsc::UnboundedReceiver;

/// Every async step's own deadline: far above what any of them takes.
pub const DEADLINE: Duration = Duration::from_secs(10);

pub async fn with_deadline<T>(label: &str, work: impl Future<Output = T>) -> T {
    match tokio::time::timeout(DEADLINE, work).await {
        Ok(done) => done,
        Err(_) => panic!("{label} did not finish within {DEADLINE:?}"),
    }
}

pub struct Head {
    dir: TempDir,
    core: Core,
    outgoing: UnboundedReceiver<Outgoing>,
    /// Stream signals read past while waiting for another kind.
    unread: VecDeque<Outgoing>,
    /// Each run session's plan as folded from its views so far.
    plans: HashMap<u64, PlanView>,
    next_id: u64,
}

impl Head {
    /// A head initialised over a fresh support directory, as `name`.
    pub async fn new(name: &str) -> Head {
        let dir = tempfile::tempdir().unwrap_or_else(|error| panic!("temp dir: {error}"));
        let home = dir.path().to_string_lossy().into_owned();
        let facts = HostFacts::new(Platform::HOST, Some(home.clone()), Vec::new(), home);
        let (out, outgoing) = Outbox::channel();
        let mut head = Head {
            core: Core::new(facts, out),
            dir,
            outgoing,
            unread: VecDeque::new(),
            plans: HashMap::new(),
            next_id: 0,
        };
        let support_dir = Some(head.path("support").to_string_lossy().into_owned());
        let init = CoreCommand::Init {
            support_dir,
            device_name: name.to_owned(),
        };
        assert!(matches!(
            head.ask(init).await.1,
            ReplyResult::Initialised(_)
        ));
        head
    }

    /// `leaf` under this head's temp dir (not created).
    pub fn path(&self, leaf: &str) -> PathBuf {
        self.dir.path().join(leaf)
    }

    pub fn path_text(&self, leaf: &str) -> String {
        self.path(leaf).to_string_lossy().into_owned()
    }

    /// The state directory the hub resolved: the support dir plus the leaf.
    pub fn state(&self) -> PathBuf {
        self.path("support").join(DIR_LEAF)
    }

    /// Sends `command` with a fresh id; the id (a session's, for commands
    /// that start one) and the reply.
    pub async fn ask(&mut self, command: CoreCommand) -> (u64, ReplyResult) {
        self.next_id += 1;
        let id = self.next_id;
        let reply = with_deadline("a reply", self.core.handle(id, command)).await;
        assert_eq!(reply.id, id, "a reply answers its own request");
        (id, reply.result)
    }

    /// The reply, which must not be a failure.
    pub async fn ok(&mut self, command: CoreCommand) -> (u64, ReplyResult) {
        let (id, result) = self.ask(command).await;
        if let ReplyResult::Failed { message } = &result {
            panic!("the command failed: {message}");
        }
        (id, result)
    }

    /// The failure message the command must answer with.
    pub async fn failure(&mut self, command: CoreCommand) -> String {
        match self.ask(command).await.1 {
            ReplyResult::Failed { message } => message,
            _ => panic!("the command should have failed"),
        }
    }

    async fn next_matching(&mut self, mut wanted: impl FnMut(&Outgoing) -> bool) -> Outgoing {
        if let Some(at) = self.unread.iter().position(&mut wanted)
            && let Some(found) = self.unread.remove(at)
        {
            return found;
        }
        loop {
            let Some(next) = with_deadline("the next signal", self.outgoing.recv()).await else {
                panic!("the hub stopped sending");
            };
            if wanted(&next) {
                return next;
            }
            self.unread.push_back(next);
        }
    }

    /// The session's next run view, its plan update folded onto the plan
    /// this head holds for the session.
    pub async fn run_view(&mut self, session: u64) -> FoldedRunView {
        let wanted = |out: &Outgoing| matches!(out, Outgoing::Run(s) if s.session == session);
        let view = match self.next_matching(wanted).await {
            Outgoing::Run(snapshot) => snapshot.view,
            _ => unreachable!("matched a run snapshot"),
        };
        let RunView {
            dry_run,
            phase,
            standing,
            entries,
            current,
            connected_at_ms,
            replicas,
            plan,
            applied,
            failed,
            timings,
            ..
        } = view;
        let plan = fold(self.plans.remove(&session), plan);
        let folded = FoldedRunView {
            exceeded_warn_size_bytes: plan.as_ref().and_then(|plan| plan.exceeded_warn_size_bytes),
            dry_run,
            phase,
            standing,
            entries,
            current,
            connected_at_ms,
            replicas,
            plan: plan
                .as_ref()
                .map_or_else(Vec::new, |plan| plan.actions.clone()),
            conflicts: plan
                .as_ref()
                .map_or_else(Vec::new, |plan| plan.conflicts.clone()),
            applied,
            failed,
            timings,
        };
        if let Some(plan) = plan {
            self.plans.insert(session, plan);
        }
        folded
    }

    /// Every run snapshot up to and including the one `stop` accepts.
    pub async fn run_until(
        &mut self,
        session: u64,
        stop: impl Fn(&FoldedRunView) -> bool,
    ) -> Vec<FoldedRunView> {
        let mut seen = Vec::new();
        loop {
            let view = self.run_view(session).await;
            let done = stop(&view);
            seen.push(view);
            if done {
                return seen;
            }
        }
    }

    pub async fn serve_view(&mut self, session: u64) -> ServeView {
        self.serve_snapshot(session).await.view
    }

    pub async fn serve_snapshot(&mut self, session: u64) -> ServeSnapshot {
        let wanted = |out: &Outgoing| matches!(out, Outgoing::Serve(s) if s.session == session);
        match self.next_matching(wanted).await {
            Outgoing::Serve(snapshot) => snapshot,
            _ => unreachable!("matched a serve snapshot"),
        }
    }

    pub async fn pairing_view(&mut self, session: u64) -> PairingView {
        self.pairing_snapshot(session).await.view
    }

    pub async fn pairing_snapshot(&mut self, session: u64) -> PairingSnapshot {
        let wanted = |out: &Outgoing| matches!(out, Outgoing::Pairing(s) if s.session == session);
        match self.next_matching(wanted).await {
            Outgoing::Pairing(snapshot) => snapshot,
            _ => unreachable!("matched a pairing snapshot"),
        }
    }
}

pub fn write(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap_or_else(|error| panic!("mkdir: {error}"));
    }
    std::fs::write(path, text).unwrap_or_else(|error| panic!("write {path:?}: {error}"));
}

pub fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|error| panic!("read {path:?}: {error}"))
}

/// A profile of one folder entry.
pub fn one_entry(a: ReplicaLocation, b: ReplicaLocation) -> Profile {
    Entry::folder(a, b)
        .map_err(|error| error.to_string())
        .and_then(|entry| Profile::new(vec![entry]).map_err(|error| error.to_string()))
        .unwrap_or_else(|error| panic!("{error}"))
}

/// A run view with its plan folded whole, as the head shows it: the
/// fields of [`RunView`] these tests read, and the plan's rows (empty
/// while there is none).
pub struct FoldedRunView {
    pub dry_run: bool,
    pub phase: RunPhaseView,
    pub standing: RunStandingView,
    pub entries: Vec<EntryRunView>,
    pub current: Option<u32>,
    pub connected_at_ms: Option<i64>,
    pub replicas: Option<ReplicasView>,
    pub plan: Vec<PlanRowView>,
    pub conflicts: Vec<ConflictRowView>,
    pub exceeded_warn_size_bytes: Option<u64>,
    pub applied: u64,
    pub failed: u64,
    pub timings: Option<String>,
}

/// `update` applied to the plan `held`, strictly: a `Same` with no plan
/// held, or naming a row the plan does not have, is the hub's bug.
fn fold(held: Option<PlanView>, update: PlanUpdateView) -> Option<PlanView> {
    match update {
        PlanUpdateView::Absent => None,
        PlanUpdateView::New(plan) => Some(plan),
        PlanUpdateView::Same { actions, conflicts } => {
            let Some(mut plan) = held else {
                panic!("a `Same` plan update arrived with no plan held");
            };
            for update in actions {
                let Some(row) = plan.actions.get_mut(update.index as usize) else {
                    panic!("a `Same` update names action row {}", update.index);
                };
                row.choice = update.choice;
                row.outcome = update.outcome;
            }
            for update in conflicts {
                let Some(row) = plan.conflicts.get_mut(update.index as usize) else {
                    panic!("a `Same` update names conflict row {}", update.index);
                };
                row.choice = update.choice;
                row.outcome = update.outcome;
            }
            Some(plan)
        }
    }
}
