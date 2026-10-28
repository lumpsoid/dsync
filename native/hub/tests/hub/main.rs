//! The hub's handlers, driven as the head drives them - commands in,
//! replies and stream signals out - over real core flows on temp state
//! dirs. No rinf: the signal plumbing is a shell around these.

mod commands;
mod compare;
mod pairing;
mod run;
mod support;
