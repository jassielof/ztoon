//! TOON (Tabular Object Notation) library for Zig
//!
//! This library provides encoding and decoding functionality for the TOON format,
//! a human-readable data serialization format designed for tabular data and
//! configuration files.
//!
//! TOON combines the readability of YAML with the simplicity of JSON, featuring:
//! - Indentation-based structure for nested objects
//! - Array headers with explicit lengths
//! - Tabular format for arrays of homogeneous objects
//! - Multiple delimiter options (comma, tab, pipe)
//! - Path expansion for simplified nested key definitions
//!
//! ## Basic Usage
//!
//! Encoding JSON to TOON:
//! ```zig
//! const value = ztoon.Value{ .object = ... };
//! const toon_str = try ztoon.encode(allocator, value, .{});
//! defer allocator.free(toon_str);
//! ```
//!
//! Decoding TOON to JSON:
//! ```zig
//! const input = "name: Alice\nage: 30";
//! var value = try ztoon.decode(allocator, input, .{});
//! defer value.deinit(allocator);
//! ```

const std = @import("std");

pub const types = @import("types.zig");
pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");
pub const errors = @import("errors.zig");

/// Represents a JSON-compatible value that can be encoded/decoded
pub const Value = types.Value;

/// Delimiter types for separating array elements
pub const Delimiter = types.Delimiter;

/// Configuration options for encoding values to TOON format
pub const EncodeOptions = types.EncodeOptions;

/// Configuration options for decoding TOON format to values
pub const DecodeOptions = types.DecodeOptions;

/// Errors that can occur during command execution
pub const CommandError = errors.CommandError;

/// Encodes a Value to TOON format string
pub const encode = encoder.encode;

/// Decodes a TOON format string to a Value
pub const decode = decoder.decode;
