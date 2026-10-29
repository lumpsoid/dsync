//! Every `dsync-core` integration test in one binary, so a change links it
//! once instead of once per group. Each group is a module here.

mod cut_link;
mod pairing;
mod peer;
mod replica;
mod run;
mod scan;
mod stores;
