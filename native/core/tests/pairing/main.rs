//! Pairing (SPEC §4.4, plan D6): the enrolment listener and dialer over
//! real TLS on loopback (`127.0.0.1:0`), real temp dirs, no mocks. The
//! timers under a paused clock are `enrolment_listener`'s unit tests.

mod bounds;
mod enrolment;
mod support;
