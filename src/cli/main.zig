//! TOON command-line interface
//!
//! This CLI tool provides commands for converting between JSON and TOON formats.
//! It can read from files or stdin and outputs to stdout.
//!
//! ## Commands
//!
//! - `encode [file]`: Convert JSON to TOON format
//! - `decode [file]`: Convert TOON to JSON format
//! - `help`: Display usage information
//!
//! ## Examples
//!
//! Encode JSON file to TOON:
//! ```sh
//! ztoon encode input.json > output.toon
//! ```
//!
//! Decode TOON from stdin:
//! ```sh
//! cat input.toon | ztoon decode > output.json
//! ```

const std = @import("std");
const ztoon = @import("ztoon");
const CommandError = ztoon.CommandError;

/// Main entry point for the TOON CLI.
///
/// Parses command-line arguments and dispatches to appropriate command handler.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    const rest_args: [][:0]const u8 = @ptrCast(args[2..]);

    if (std.mem.eql(u8, command, "encode")) {
        try encodeCommand(allocator, rest_args);
    } else if (std.mem.eql(u8, command, "decode")) {
        try decodeCommand(allocator, rest_args);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        return;
    }
}

/// Prints usage information to stdout.
///
/// Displays available commands and basic usage examples.
fn printUsage() !void {
    const usage =
        \\Usage: ztoon <command> [options]
        \\
        \\Commands:
        \\  encode [file]    Encode JSON to TOON format
        \\  decode [file]    Decode TOON to JSON format
        \\  help             Show this help message
        \\
        \\If no file is provided, reads from stdin.
        \\
    ;
    var stdout_buffer: [usage.len]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}", .{usage});
    try stdout.flush();
}

/// Handles the 'encode' command - converts JSON to TOON.
///
/// Reads JSON input from a file or stdin, parses it, converts to TOON format,
/// and writes the result to stdout.
///
/// Parameters:
/// - `allocator`: Memory allocator
/// - `args`: Command arguments (optional filename)
fn encodeCommand(allocator: std.mem.Allocator, args: [][:0]const u8) !void {
    // Read input (from file or stdin)
    const input = if (args.len > 0)
        try std.fs.cwd().readFileAlloc(allocator, args[0], 1024 * 1024)
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(input);

    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();

    // Convert to toon.Value
    var value = try jsonValueToToonValue(allocator, parsed.value);
    defer value.deinit(allocator);

    // Encode to TOON
    const output = try ztoon.encode(allocator, value, .{});
    defer allocator.free(output);

    // Write to stdout
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(output);
    try stdout.writeAll("\n");
}

/// Handles the 'decode' command - converts TOON to JSON.
///
/// Reads TOON input from a file or stdin, parses it, converts to JSON format,
/// and writes the result to stdout.
///
/// Parameters:
/// - `allocator`: Memory allocator
/// - `args`: Command arguments (optional filename)
fn decodeCommand(allocator: std.mem.Allocator, args: [][:0]const u8) !void {
    // Read input (from file or stdin)
    const input = if (args.len > 0)
        try std.fs.cwd().readFileAlloc(allocator, args[0], 1024 * 1024)
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(input);

    // Decode from TOON
    var value = try ztoon.decode(allocator, input, .{});
    defer value.deinit(allocator);

    // Convert to JSON and write directly to stdout
    const stdout = std.fs.File.stdout();
    try writeJson(stdout, value, 0);
    try stdout.writeAll("\n");
}

/// Writes a TOON Value as formatted JSON to a file.
///
/// Recursively serializes the value with proper indentation and formatting.
///
/// Parameters:
/// - `file`: File to write output to
/// - `value`: The TOON value to serialize
/// - `indent`: Current indentation level
fn writeJson(file: std.fs.File, value: ztoon.Value, indent: usize) anyerror!void {
    switch (value) {
        .null => try file.writeAll("null"),
        .bool => |b| try file.writeAll(if (b) "true" else "false"),
        .number => |n| {
            var buf: [64]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
            try file.writeAll(str);
        },
        .string => |s| {
            try file.writeAll("\"");
            for (s) |c| {
                switch (c) {
                    '\n' => try file.writeAll("\\n"),
                    '\r' => try file.writeAll("\\r"),
                    '\t' => try file.writeAll("\\t"),
                    '\\' => try file.writeAll("\\\\"),
                    '"' => try file.writeAll("\\\""),
                    else => try file.writeAll(&[_]u8{c}),
                }
            }
            try file.writeAll("\"");
        },
        .array => |arr| {
            try file.writeAll("[\n");
            for (arr, 0..) |item, i| {
                try writeIndentSpaces(file, indent + 1);
                try writeJson(file, item, indent + 1);
                if (i < arr.len - 1) {
                    try file.writeAll(",");
                }
                try file.writeAll("\n");
            }
            try writeIndentSpaces(file, indent);
            try file.writeAll("]");
        },
        .object => |obj| {
            try file.writeAll("{\n");
            var iter = obj.iterator();
            var count: usize = 0;
            const total = obj.count();
            while (iter.next()) |entry| {
                try writeIndentSpaces(file, indent + 1);
                try file.writeAll("\"");
                try file.writeAll(entry.key_ptr.*);
                try file.writeAll("\": ");
                try writeJson(file, entry.value_ptr.*, indent + 1);
                count += 1;
                if (count < total) {
                    try file.writeAll(",");
                }
                try file.writeAll("\n");
            }
            try writeIndentSpaces(file, indent);
            try file.writeAll("}");
        },
    }
}

/// Writes indentation spaces to a file.
///
/// Parameters:
/// - `file`: File to write to
/// - `indent`: Number of indentation levels (each level is 2 spaces)
fn writeIndentSpaces(file: std.fs.File, indent: usize) !void {
    var i: usize = 0;
    while (i < indent * 2) : (i += 1) {
        try file.writeAll(" ");
    }
}

/// Converts std.json.Value to ztoon.Value.
///
/// Recursively converts a JSON parse tree into a TOON Value structure,
/// handling all JSON types including nested objects and arrays.
///
/// Parameters:
/// - `allocator`: Memory allocator for new Value construction
/// - `json_val`: The JSON value to convert
///
/// Returns:
/// - A ztoon.Value equivalent of the JSON value
fn jsonValueToToonValue(allocator: std.mem.Allocator, json_val: std.json.Value) !ztoon.Value {
    return switch (json_val) {
        .null => ztoon.Value{ .null = {} },
        .bool => |b| ztoon.Value{ .bool = b },
        .integer => |i| ztoon.Value{ .number = @floatFromInt(i) },
        .float => |f| ztoon.Value{ .number = f },
        .number_string => |s| blk: {
            const num = try std.fmt.parseFloat(f64, s);
            break :blk ztoon.Value{ .number = num };
        },
        .string => |s| ztoon.Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var items = try allocator.alloc(ztoon.Value, arr.items.len);
            errdefer allocator.free(items);

            for (arr.items, 0..) |item, i| {
                items[i] = try jsonValueToToonValue(allocator, item);
            }

            break :blk ztoon.Value{ .array = items };
        },
        .object => |obj| blk: {
            var map = std.StringArrayHashMap(ztoon.Value).init(allocator);
            errdefer map.deinit();

            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try jsonValueToToonValue(allocator, entry.value_ptr.*);
                try map.put(key, val);
            }

            break :blk ztoon.Value{ .object = map };
        },
    };
}
