//! A hub as the head drives it, without rinf: a [`Core`] over a temp
//! support directory (the mobile rule, so nothing touches this machine's
//! real state), commands in, replies and stream signals out.

use std::collections::VecDeque;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::time::Duration;

use dsync_domain::{DIR_LEAF, HostFacts, Platform};
use hub::signals::{CoreCommand, EnrolmentUpdateBody, ReplyResult, RunUpdateBody, ServeUpdateBody};
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

    pub async fn run_update(&mut self, session: u64) -> RunUpdateBody {
        let wanted = |out: &Outgoing| matches!(out, Outgoing::Run(u) if u.session == session);
        match self.next_matching(wanted).await {
            Outgoing::Run(update) => update.update,
            _ => unreachable!("matched a run update"),
        }
    }

    /// Every run update up to and including the one `stop` accepts.
    pub async fn run_until(
        &mut self,
        session: u64,
        stop: impl Fn(&RunUpdateBody) -> bool,
    ) -> Vec<RunUpdateBody> {
        let mut seen = Vec::new();
        loop {
            let update = self.run_update(session).await;
            let done = stop(&update);
            seen.push(update);
            if done {
                return seen;
            }
        }
    }

    pub async fn serve_update(&mut self, session: u64) -> ServeUpdateBody {
        let wanted = |out: &Outgoing| matches!(out, Outgoing::Serve(u) if u.session == session);
        match self.next_matching(wanted).await {
            Outgoing::Serve(update) => update.update,
            _ => unreachable!("matched a serve update"),
        }
    }

    pub async fn enrolment_update(&mut self, session: u64) -> EnrolmentUpdateBody {
        let wanted = |out: &Outgoing| matches!(out, Outgoing::Enrolment(u) if u.session == session);
        match self.next_matching(wanted).await {
            Outgoing::Enrolment(update) => update.update,
            _ => unreachable!("matched an enrolment update"),
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
