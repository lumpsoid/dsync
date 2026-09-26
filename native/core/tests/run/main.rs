//! `Run` end to end over real replicas: its order and events, the apply's
//! stages, the missing-root rule, the connector, and the convergence soak -
//! local against local and against a replica served over the protocol.

mod apply;
mod changed;
mod connect;
mod flow;
mod missing_root;
mod pipeline;
mod soak;
mod support;
