//! Error types for the TOON library
//!
//! This module defines error types that can be returned by TOON operations.

/// Errors that can occur during command execution.
///
/// These errors are primarily used by the CLI but may also be relevant
/// for library users implementing custom command-line tools.
pub const CommandError = error{
    UnknownCommand,
    InvalidArguments,
    FileNotFound,
};
