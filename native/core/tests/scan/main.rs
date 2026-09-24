//! The scanner, its session, the case-fold probe, the scan probe and the
//! filter-preview listing, against real temp trees.

mod case_folding;
mod filter_listing;
mod probe;
mod scanner;
mod session;
mod support;
#[cfg(unix)]
mod symlinks;
#[cfg(unix)]
mod unreadable;
