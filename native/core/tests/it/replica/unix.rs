//! The unix-socket transport: `bind_unix` / `dial_unix` and a listener
//! serving each connection as its own session (the unix parts of
//! `agent_listener.dart`).

use std::fs;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::sync::Arc;

use dsync_core::{
    LinkError, RemoteReplica, Replica, ReplicaServer, UnixBindError, bind_unix, dial_unix,
};
use dsync_domain::{Side, Tuning};
use tokio::sync::mpsc;

use crate::replica::served::{open_local, spec};
use crate::replica::support::{Site, with_deadline};

#[tokio::test]
async fn a_listener_serves_each_connection_as_its_own_session() {
    let site = Site::new();
    let socket = site.dir().join("agent.sock");
    let listener = bind_unix(&socket).await.unwrap();
    let server = Arc::new(ReplicaServer::new(
        open_local(site.state()),
        Tuning::DEFAULT,
    ));
    let (ended, mut sessions) = mpsc::unbounded_channel::<Result<(), LinkError>>();
    let listening = tokio::spawn(server.serve_unix(listener, move |end| {
        let _ = ended.send(end);
    }));

    // A client that dies holding the lock...
    let dropped = with_deadline(
        "connect",
        RemoteReplica::connect(
            dial_unix(&socket).await.unwrap(),
            spec(&site, Side::B),
            &Tuning::DEFAULT,
        ),
    )
    .await
    .unwrap();
    with_deadline("hello", dropped.hello()).await.unwrap();
    with_deadline("lock", dropped.lock()).await.unwrap();
    drop(dropped);
    with_deadline("the first session's end", sessions.recv())
        .await
        .unwrap()
        .unwrap();

    // ...leaves it free for the next, while the listener outlives both.
    let next = with_deadline(
        "connect again",
        RemoteReplica::connect(
            dial_unix(&socket).await.unwrap(),
            spec(&site, Side::B),
            &Tuning::DEFAULT,
        ),
    )
    .await
    .unwrap();
    with_deadline("hello", next.hello()).await.unwrap();
    with_deadline("lock", next.lock()).await.unwrap();
    with_deadline("unlock", next.unlock()).await.unwrap();
    with_deadline("close", next.close()).await.unwrap();
    with_deadline("the second session's end", sessions.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(!listening.is_finished());
    listening.abort();
}

#[tokio::test]
async fn a_stale_socket_left_by_a_killed_agent_is_cleared() {
    let site = Site::new();
    let socket = site.dir().join("agent.sock");
    drop(StdUnixListener::bind(&socket).unwrap());
    assert!(socket.exists(), "the stale socket is there to clear");
    let listener = bind_unix(&socket).await.unwrap();
    drop(listener);
}

#[tokio::test]
async fn a_live_socket_is_left_to_the_agent_serving_it() {
    let site = Site::new();
    let socket = site.dir().join("agent.sock");
    let _live = bind_unix(&socket).await.unwrap();
    let refused = bind_unix(&socket).await;
    assert!(
        matches!(&refused, Err(UnixBindError::AlreadyServed { path }) if path == &socket),
        "{refused:?}"
    );
    assert!(socket.exists());
}

#[tokio::test]
async fn a_file_that_is_not_a_socket_is_never_removed() {
    let site = Site::new();
    let socket = site.dir().join("agent.sock");
    fs::write(&socket, "not a socket").unwrap();
    let refused = bind_unix(&socket).await;
    assert!(
        matches!(refused, Err(UnixBindError::Io { .. })),
        "{refused:?}"
    );
    assert_eq!(fs::read(&socket).unwrap(), b"not a socket");
}
