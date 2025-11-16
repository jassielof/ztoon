//! Core data types for the TOON library
//!
//! This module defines the fundamental types used throughout the TOON encoder
//! and decoder, including the Value type for representing data, delimiter types,
//! and configuration options.

const std = @import("std");

/// Represents a JSON-compatible value that can be encoded to or decoded from TOON.
///
/// The Value type is a tagged union that can represent any valid JSON data structure:
/// - `null`: JSON null value
/// - `bool`: Boolean true/false
/// - `number`: 64-bit floating point number
/// - `string`: UTF-8 string slice
/// - `array`: Dynamic array of Values
/// - `object`: String-keyed hash map of Values
///
/// ## Memory Management
///
/// Values own their memory and must be freed using `deinit()` when no longer needed.
/// This recursively frees all nested structures.
///
/// ## Example
///
/// ```zig
/// var value = Value{ .string = try allocator.dupe(u8, "hello") };
/// defer value.deinit(allocator);
/// ```
pub const Value = union(enum) {
    null: void,
    bool: bool,
    number: f64,
    string: []const u8,
    array: []Value,
    object: std.StringArrayHashMap(Value),

    /// Recursively frees all memory owned by this Value.
    ///
    /// This function handles cleanup for strings, arrays, and objects,
    /// recursively freeing nested structures. Safe to call on all value types.
    ///
    /// Parameters:
    /// - `self`: Pointer to the Value to free
    /// - `allocator`: The allocator used to allocate this Value's memory
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }
};

/// Delimiter types for separating elements in TOON arrays.
///
/// TOON supports three delimiter types for array elements:
/// - `comma`: Standard comma separator (default)
/// - `tab`: Tab character separator (useful for TSV-style data)
/// - `pipe`: Pipe character separator (useful when data contains commas)
///
/// The delimiter can be specified in array headers and is automatically
/// detected during parsing.
pub const Delimiter = enum {
    comma,
    tab,
    pipe,

    /// Converts a Delimiter enum value to its character representation.
    ///
    /// Returns:
    /// - `','` for comma
    /// - `'\t'` for tab
    /// - `'|'` for pipe
    pub fn toChar(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .pipe => '|',
        };
    }

    /// Attempts to convert a character to a Delimiter enum value.
    ///
    /// Returns `null` if the character does not represent a valid delimiter.
    ///
    /// Parameters:
    /// - `c`: The character to convert
    ///
    /// Returns:
    /// - `.comma` for ','
    /// - `.tab` for '\t'
    /// - `.pipe` for '|'
    /// - `null` for any other character
    pub fn fromChar(c: u8) ?Delimiter {
        return switch (c) {
            ',' => .comma,
            '\t' => .tab,
            '|' => .pipe,
            else => null,
        };
    }
};

/// Configuration options for encoding values to TOON format.
///
/// These options control the formatting and style of the generated TOON output.
///
/// ## Fields
///
/// - `indent`: Number of spaces per indentation level (default: 2)
/// - `delimiter`: Delimiter character for array elements (default: comma)
///
/// ## Example
///
/// ```zig
/// const options = ztoon.EncodeOptions{
///     .indent = 4,
///     .delimiter = .pipe,
/// };
/// const output = try ztoon.encode(allocator, value, options);
/// ```
pub const EncodeOptions = struct {
    indent: usize = 2,
    delimiter: Delimiter = .comma,
};

/// Configuration options for decoding TOON format to values.
///
/// These options control the parsing behavior and validation level.
///
/// ## Fields
///
/// - `indent`: Expected number of spaces per indentation level (default: 2)
/// - `strict`: Whether to enforce strict parsing rules (default: false)
///
/// ## Example
///
/// ```zig
/// const options = ztoon.DecodeOptions{
///     .indent = 4,
///     .strict = true,
/// };
/// var value = try ztoon.decode(allocator, toon_input, options);
/// ```
pub const DecodeOptions = struct {
    indent: usize = 2,
    strict: bool = false,
};
