//! peer:// over rustls (SPEC §4.4, plan D6): the pinning verifiers on both
//! ends, the listener's bounds and grants, the dialer's resolution and
//! recording, and a replica round trip over it all. Real TLS on loopback
//! (`127.0.0.1:0`), real temp dirs, no mocks.

mod both_ends;
mod bounds;
mod dialer;
mod grants;
mod links;
mod listener;
mod reclaim;
mod redial;
mod rename;
mod round_trip;
mod support;
mod verifiers;
