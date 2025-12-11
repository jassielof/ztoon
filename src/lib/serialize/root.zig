//! TOON stringification/serialization API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../Value.zig").Value;
const OptionsType = @import("Options.zig");
const normalize = @import("normalize.zig");
const encoders = @import("encoders.zig");

pub const serialize = @This();
pub const Options = OptionsType;

/// Stringifies a std.json.Value to TOON format.
/// Returns an allocated string that the caller must free.
pub fn stringify(
    json_value: std.json.Value,
    options: OptionsType,
    allocator: Allocator,
) Allocator.Error![]const u8 {
    // Normalize JSON value to our Value type
    const value = try normalize.normalizeJsonValue(allocator, json_value);
    defer value.deinit(allocator);

    // Use a writer to collect the output
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    encoders.encodeValue(value, options, list.writer(), 0, allocator) catch |err| switch (err) {
        error.InvalidType => return error.OutOfMemory, // Should never happen
        else => |e| return e,
    };

    // Per SPEC §12: No trailing newline at the end of the document
    const slice = try list.toOwnedSlice();
    if (slice.len > 0 and slice[slice.len - 1] == '\n') {
        const trimmed = try allocator.dupe(u8, slice[0 .. slice.len - 1]);
        allocator.free(slice);
        return trimmed;
    }
    return slice;
}

/// Stringifies a Value to TOON format.
/// Returns an allocated string that the caller must free.
pub fn stringifyValue(
    value: Value,
    options: OptionsType,
    allocator: Allocator,
) Allocator.Error![]const u8 {
    // Use a writer to collect the output
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    encoders.encodeValue(value, options, list.writer(), 0, allocator) catch |err| switch (err) {
        error.InvalidType => return error.OutOfMemory, // Should never happen
        else => |e| return e,
    };

    // Per SPEC §12: No trailing newline at the end of the document
    const slice = try list.toOwnedSlice();
    if (slice.len > 0 and slice[slice.len - 1] == '\n') {
        const trimmed = try allocator.dupe(u8, slice[0 .. slice.len - 1]);
        allocator.free(slice);
        return trimmed;
    }
    return slice;
}

/// Stringifies a std.json.Value to TOON format, writing to a writer.
/// This is useful for streaming large outputs.
pub fn stringifyToWriter(
    json_value: std.json.Value,
    options: OptionsType,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    // Normalize JSON value to our Value type
    const value = try normalize.normalizeJsonValue(allocator, json_value);
    defer value.deinit(allocator);

    encoders.encodeValue(value, options, writer, 0, allocator) catch |err| switch (err) {
        error.InvalidType => return error.OutOfMemory, // Should never happen
        else => |e| return e,
    };
}

/// Stringifies a Value to TOON format, writing to a writer.
/// This is useful for streaming large outputs.
pub fn stringifyValueToWriter(
    value: Value,
    options: OptionsType,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    encoders.encodeValue(value, options, writer, 0, allocator) catch |err| switch (err) {
        error.InvalidType => return error.OutOfMemory, // Should never happen
        else => |e| return e,
    };
}

/// Main Stringify API struct, similar to std.json.Stringify.
pub const Stringify = struct {
    /// Stringifies a std.json.Value to TOON format.
    pub fn value(
        json_value: std.json.Value,
        options: OptionsType,
        allocator: Allocator,
    ) Allocator.Error![]const u8 {
        return stringify(json_value, options, allocator);
    }

    /// Stringifies a std.json.Value to TOON format, writing to a writer.
    pub fn valueToWriter(
        json_value: std.json.Value,
        options: OptionsType,
        writer: anytype,
        allocator: Allocator,
    ) (@TypeOf(writer).Error || Allocator.Error)!void {
        return stringifyToWriter(json_value, options, writer, allocator);
    }
};
