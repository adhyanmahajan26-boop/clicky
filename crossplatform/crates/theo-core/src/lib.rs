//! Theo's harness engine, shared by the Mac, Windows and Linux builds.
//!
//! It owns the bots, their chats, group chats, private threads between bots and routines, runs each bot turn on an engine
//! (Claude Code's `claude -p`, or a stand-in in tests), and holds the limits the Swift app holds: the caps on bots messaging
//! each other, group turn order, retries and fallback models, routines with a catch-up window, crash recovery, the local API,
//! hooks, usage and the health check. Everything a test or the desktop app does goes through [`harness::Harness`].

pub mod paths;
pub mod settings;
pub mod model;
pub mod store;
pub mod protocol;
pub mod prompts;
pub mod schedule;
pub mod failover;
pub mod engine;
pub mod procs;
pub mod policy;
pub mod usage;
pub mod hooks;
pub mod gateway;
pub mod secrets;
pub mod harness;
pub mod control;
pub mod coding;

pub use harness::Harness;
