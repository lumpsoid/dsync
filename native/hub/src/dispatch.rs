//! One command in, one reply out. [`Core`] holds the hub from `Init` on;
//! [`Hub`] holds what every command works over - this host's facts, its
//! state and config directories, the live sessions - and routes each
//! command to the core flow that answers it.

use std::fmt::Display;
use std::sync::{Arc, Mutex, PoisonError};

use dsync_core::{ProfileStore, StateDir};
use dsync_domain::{DirPath, DirRule, HostFacts, StateDirChoice, Tuning};

use crate::outbox::Outbox;
use crate::sessions::Sessions;
use crate::signals::{CoreCommand, CoreReply, ReplyResult};

/// A command's answer, or the message saying why there is none.
pub(crate) type Handled = Result<ReplyResult, String>;

/// A failure as the head shows it: the core's own words.
pub(crate) fn text(error: impl Display) -> String {
    error.to_string()
}

/// Runs blocking file work off the runtime's threads.
pub(crate) async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    match tokio::task::spawn_blocking(work).await {
        Ok(done) => done,
        Err(error) => match error.try_into_panic() {
            Ok(panic) => std::panic::resume_unwind(panic),
            Err(_) => Err("the core shut down mid-command".to_owned()),
        },
    }
}

/// The hub before and after `Init`.
pub struct Core {
    facts: HostFacts,
    out: Outbox,
    hub: Mutex<Option<Arc<Hub>>>,
}

impl Core {
    /// `facts` are this process's, read once by the shell; stream signals
    /// go to `out`.
    pub fn new(facts: HostFacts, out: Outbox) -> Core {
        Core {
            facts,
            out,
            hub: Mutex::new(None),
        }
    }

    /// Answers request `id`.
    pub async fn handle(&self, id: u64, command: CoreCommand) -> CoreReply {
        let result = match command {
            CoreCommand::Init {
                support_dir,
                device_name,
            } => self.init(support_dir, device_name),
            command => match self.hub() {
                Some(hub) => hub.handle(id, command).await,
                None => Err("the core is not initialised: send Init first".to_owned()),
            },
        };
        CoreReply {
            id,
            result: result.unwrap_or_else(|message| ReplyResult::Failed { message }),
        }
    }

    fn hub(&self) -> Option<Arc<Hub>> {
        self.hub
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// A second `Init` (a Dart hot restart) replaces the first; sessions
    /// already running go on under the hub that started them.
    fn init(&self, support_dir: Option<String>, device_name: String) -> Handled {
        let rule = match support_dir {
            Some(dir) => DirRule::HostSupplied(DirPath::parse(&dir).map_err(text)?),
            None => DirRule::HOST,
        };
        let state =
            StateDir::resolve(&StateDirChoice::Rule(rule.clone()), &self.facts).map_err(text)?;
        let profiles = ProfileStore::resolve(&rule, &self.facts).map_err(text)?;
        let hub = Hub {
            facts: self.facts.clone(),
            state,
            profiles,
            device_name,
            tuning: Tuning::DEFAULT,
            out: self.out.clone(),
            sessions: Sessions::default(),
        };
        *self.hub.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(hub));
        Ok(ReplyResult::Done)
    }
}

/// What every command works over.
pub(crate) struct Hub {
    pub facts: HostFacts,
    pub state: StateDir,
    pub profiles: ProfileStore,
    /// The common name of an identity created here.
    pub device_name: String,
    pub tuning: Tuning,
    pub out: Outbox,
    pub sessions: Sessions,
}

impl Hub {
    async fn handle(&self, id: u64, command: CoreCommand) -> Handled {
        match command {
            CoreCommand::Init { .. } => Err("Init is the core's own".to_owned()),
            CoreCommand::ShowIdentity => self.show_identity(),
            CoreCommand::RenewIdentity { common_name } => self.renew_identity(common_name),
            CoreCommand::ShowPairing {
                name,
                bind,
                advertise,
                service_port,
            } => {
                self.show_pairing(id, &name, &bind, advertise, service_port)
                    .await
            }
            CoreCommand::ConfirmPairing { session, accept } => {
                self.confirm_pairing(session, accept)
            }
            CoreCommand::CancelPairing { session } => self.cancel_pairing(session),
            CoreCommand::ReadPairCode { text } => Ok(self.read_pair_code(&text)),
            CoreCommand::AcceptPairing { code, name } => self.accept_pairing(&code, &name).await,
            CoreCommand::ListDevices => self.list_devices(),
            CoreCommand::RenameDevice { device_id, name } => self.rename_device(&device_id, &name),
            CoreCommand::RevokeDevice { device_id } => self.revoke_device(&device_id),
            CoreCommand::GrantRoot { device_id, path } => self.grant_root(&device_id, &path),
            CoreCommand::WithdrawGrant { device_id, root } => {
                self.withdraw_grant(&device_id, &root)
            }
            CoreCommand::ProbePeer { device_id, address } => {
                self.probe_peer(&device_id, address).await
            }
            CoreCommand::ListProfiles => self.list_profiles().await,
            CoreCommand::SaveProfile { name, draft } => self.save_profile(&name, draft).await,
            CoreCommand::RenameProfile { from, to } => self.rename_profile(&from, &to).await,
            CoreCommand::DeleteProfile { name } => self.delete_profile(&name).await,
            CoreCommand::StartRun {
                target,
                dry_run,
                address,
            } => self.start_run(id, target, dry_run, address),
            CoreCommand::DecideRun { session, decision } => self.decide_run(session, decision),
            CoreCommand::StopRun { session } => self.stop_run(session),
            CoreCommand::StartServe { bind, port } => self.start_serve(id, &bind, port).await,
            CoreCommand::StopServe { session } => self.stop_serve(session),
            CoreCommand::ServeAddresses => Ok(self.serve_addresses()),
            CoreCommand::ListArchives => self.list_archives().await,
            CoreCommand::ClearArchive { profile_id } => self.clear_archive(&profile_id).await,
            CoreCommand::PreviewFilters { root, ignore } => {
                self.preview_filters(root, &ignore).await
            }
            CoreCommand::ListFilterFolder {
                root,
                folder,
                ignore,
            } => self.list_filter_folder(root, folder, &ignore).await,
            CoreCommand::CheckFolder { path } => self.check_folder(path).await,
            CoreCommand::ProbeScan {
                root,
                ignore,
                passes,
            } => self.probe_scan(root, &ignore, passes).await,
        }
    }
}
