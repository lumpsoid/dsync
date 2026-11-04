//! The unix-socket transport (SPEC §4.2): `dsync agent --listen <socket>`
//! on this host, dialled by path, with no authentication - whoever can
//! reach the socket's directory is trusted, so the socket belongs in one
//! only its owner can enter (`$XDG_RUNTIME_DIR`).

use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use dsync_domain::ReplicaSpec;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{UnixListener, UnixStream};

use crate::link_error::LinkError;
use crate::replica::Replica;
use crate::replica_error::ReplicaError;
use crate::replica_server::ReplicaServer;
use crate::transport::Transport;

#[derive(Debug, thiserror::Error)]
pub enum UnixBindError {
    #[error("another agent is already listening on {}", path.display())]
    AlreadyServed { path: PathBuf },
    #[error("cannot listen on {}: {source}", path.display())]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// Listens on the socket at `path`, first clearing a stale socket file a
/// killed agent left behind, and makes the socket owner-only (0600).
///
/// The bind takes its mode from the umask, which could let any user on
/// the host connect; the chmod narrows it to this user whatever the umask.
/// It comes after the bind, so the directories above the socket stay the
/// real gate: no directories are created or changed, they are the
/// caller's to choose.
pub async fn bind_unix(path: &Path) -> Result<UnixListener, UnixBindError> {
    use std::os::unix::fs::PermissionsExt;
    let io = |source| UnixBindError::Io {
        path: path.to_owned(),
        source,
    };
    clear_stale_socket(path).await?;
    let listener = UnixListener::bind(path).map_err(io)?;
    if let Err(error) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        drop(listener);
        let _ = std::fs::remove_file(path);
        return Err(io(error));
    }
    Ok(listener)
}

/// Connects to the agent listening on `path`.
pub async fn dial_unix(path: &Path) -> io::Result<Transport<OwnedReadHalf, OwnedWriteHalf>> {
    let (reader, writer) = UnixStream::connect(path).await?.into_split();
    Ok(Transport::new(reader, writer))
}

/// Removes the socket at `path` when nothing is listening on it.
///
/// A socket's file outlives the process that bound it, and binding
/// refuses a path that exists, so an agent killed outright (SIGKILL, a
/// crash, power loss) would otherwise leave one to delete by hand. Whether
/// it is stale is asked of the socket itself: the kernel refuses a
/// connection with no listener at once and unambiguously; one that is
/// accepted means a live agent, which this does not unlink from under it.
/// Anything at the path that is not a socket is left for the bind to fail
/// on, naming the path.
async fn clear_stale_socket(path: &Path) -> Result<(), UnixBindError> {
    use std::os::unix::fs::FileTypeExt;
    let io = |source| UnixBindError::Io {
        path: path.to_owned(),
        source,
    };
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {}
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(io(error)),
    }
    match UnixStream::connect(path).await {
        Ok(_) => Err(UnixBindError::AlreadyServed {
            path: path.to_owned(),
        }),
        Err(_) => match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(io(error)),
        },
    }
}

impl<F> ReplicaServer<F> {
    /// Serves every connection `listener` accepts, each its own session,
    /// concurrently, until accepting fails. Each session's end is handed
    /// to `ended`; one failing does not stop the others.
    pub async fn serve_unix<Opening, R>(
        self: Arc<Self>,
        listener: UnixListener,
        ended: impl Fn(Result<(), LinkError>) + Send + Sync + 'static,
    ) -> io::Result<()>
    where
        F: Fn(ReplicaSpec) -> Opening + Send + Sync + 'static,
        Opening: Future<Output = Result<R, ReplicaError>> + Send,
        R: Replica + 'static,
    {
        let ended = Arc::new(ended);
        loop {
            let (stream, _) = listener.accept().await?;
            let (server, ended) = (self.clone(), ended.clone());
            tokio::spawn(async move {
                let (reader, writer) = stream.into_split();
                ended(server.serve(Transport::new(reader, writer)).await);
            });
        }
    }
}
