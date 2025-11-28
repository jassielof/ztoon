//! TOON formatter, similar to std.json.fmt
//! Provides a formatter that can be used with the {f} format specifier.

const std = @import("std");
const Value = @import("../Value.zig").Value;
const Options = @import("../serialize/Options.zig");

/// Returns a formatter for the given value and options.
/// Similar to std.json.fmt, this can be used with the {f} format specifier.
pub fn fmt(value: Value, options: Options) Formatter {
    return .{
        .value = value,
        .options = options,
    };
}

/// Formatter struct that implements the format interface for Zig's formatting system.
pub const Formatter = struct {
    value: Value,
    options: Options,

    /// Implements the format interface for use with {f} format specifier.
    pub fn format(
        self: @This(),
        writer: anytype,
    ) error{WriteFailed}!void {
        formatValue(self.value, self.options, writer, 0, null) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => return error.WriteFailed,
        };
    }
};

/// Formats a TOON value to the writer.
/// `parent_key` is used to determine if we're formatting a root value or nested value.
fn formatValue(
    value: Value,
    opts: Options,
    writer: anytype,
    depth: usize,
    parent_key: ?[]const u8,
) anyerror!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try formatFloat(f, writer),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try formatString(s, opts.delimiter orelse ',', writer),
        .array => |arr| try formatArray(arr, opts, writer, depth, parent_key),
        .object => |obj| try formatObject(obj, opts, writer, depth, parent_key),
    }
}

/// Formats a float value, ensuring canonical decimal representation.
fn formatFloat(f: f64, writer: anytype) anyerror!void {
    // Handle special cases
    if (std.math.isNan(f)) {
        try writer.writeAll("null");
        return;
    }
    if (std.math.isInf(f)) {
        try writer.writeAll("null");
        return;
    }
    if (f == -0.0) {
        try writer.writeAll("0");
        return;
    }

    // Format as decimal - Zig's {d} format should handle this correctly
    try writer.print("{d}", .{f});
}

/// Formats a string, adding quotes if necessary.
fn formatString(s: []const u8, delimiter: u8, writer: anytype) anyerror!void {
    // Check if string needs quoting
    const needs_quotes = needsQuoting(s, delimiter);

    if (needs_quotes) {
        try writer.writeByte('"');
        try escapeString(s, writer);
        try writer.writeByte('"');
    } else {
        try writer.writeAll(s);
    }
}

/// Determines if a string needs quoting.
fn needsQuoting(s: []const u8, delimiter: u8) bool {
    if (s.len == 0) return true;

    // Check if string looks like a number, boolean, or null
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) {
        return true;
    }

    // Check if string looks like a number (starts with digit or minus)
    if (s.len > 0) {
        const first = s[0];
        if ((first >= '0' and first <= '9') or first == '-') {
            // Simple check: if it parses as a number, it needs quoting
            // We'll do a basic validation
            var i: usize = 0;
            if (first == '-') i += 1;
            var has_digit = false;
            var has_dot = false;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c >= '0' and c <= '9') {
                    has_digit = true;
                } else if (c == '.' and !has_dot) {
                    has_dot = true;
                } else if (c == 'e' or c == 'E') {
                    // Scientific notation - needs quoting
                    return true;
                } else {
                    // Not a number
                    break;
                }
            }
            if (has_digit and i == s.len) {
                return true; // Looks like a number
            }
        }
    }

    // Check if string contains delimiter, newlines, or special characters
    for (s) |c| {
        if (c == delimiter or c == '\n' or c == '\r' or c == '"' or c == '\\') {
            return true;
        }
        // Check for control characters
        if (c < 0x20) {
            return true;
        }
    }

    return false;
}

/// Escapes special characters in a string.
fn escapeString(s: []const u8, writer: anytype) anyerror!void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Control character - escape as \uXXXX
                    try writer.print("\\u{0:0>4}", .{@as(u16, c)});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Array format detection result.
const ArrayFormat = enum {
    inline_format, // All primitives - can be inline
    tabular, // All objects with same fields - can be tabular
    list, // Mixed types or non-uniform objects - use list format
};

/// Detects the best format for an array.
fn detectArrayFormat(items: []const Value) ArrayFormat {
    if (items.len == 0) return .inline_format;

    // Check if all items are primitives
    var all_primitives = true;
    for (items) |item| {
        switch (item) {
            .null, .bool, .integer, .float, .number_string, .string => {},
            else => {
                all_primitives = false;
                break;
            },
        }
    }
    if (all_primitives) return .inline_format;

    // Check if all items are objects with the same fields
    if (items.len > 0 and items[0] == .object) {
        const first_obj = items[0].object;

        // Collect first object's field names in order
        // Use a reasonable max field count
        const max_fields = 64;
        var first_fields_buf: [max_fields][]const u8 = undefined;
        var first_fields_count: usize = 0;

        var it = first_obj.iterator();
        while (it.next()) |entry| {
            if (first_fields_count >= max_fields) {
                return .list; // Too many fields, use list format
            }
            first_fields_buf[first_fields_count] = entry.key_ptr.*;
            first_fields_count += 1;
        }
        const first_fields = first_fields_buf[0..first_fields_count];

        // Check if all objects have the same fields and all values are primitives
        var all_uniform = true;
        for (items[1..]) |item| {
            if (item != .object) {
                all_uniform = false;
                break;
            }
            const obj = item.object;

            // Check field count matches
            if (obj.count() != first_fields.len) {
                all_uniform = false;
                break;
            }

            // Check all fields exist and are primitives
            for (first_fields) |field| {
                const val = obj.get(field) orelse {
                    all_uniform = false;
                    break;
                };
                switch (val) {
                    .null, .bool, .integer, .float, .number_string, .string => {},
                    else => {
                        all_uniform = false;
                        break;
                    },
                }
            }
            if (!all_uniform) break;
        }

        if (all_uniform) return .tabular;
    }

    return .list;
}

/// Formats an array, choosing the best representation (inline, tabular, or list).
fn formatArray(
    arr: Value.Array,
    opts: Options,
    writer: anytype,
    depth: usize,
    _: ?[]const u8,
) anyerror!void {
    if (arr.items.len == 0) {
        // Empty array
        try writer.print("[0]:", .{});
        return;
    }

    // Determine array format: inline (primitives), tabular (uniform objects), or list (mixed)
    const format_type = detectArrayFormat(arr.items);

    switch (format_type) {
        .inline_format => {
            // Format as inline primitive array: key[N]: val1,val2,val3
            try writer.print("[{d}]: ", .{arr.items.len});
            const delim = opts.delimiter orelse ',';
            for (arr.items, 0..) |item, i| {
                if (i > 0) {
                    try writer.writeByte(delim);
                }
                try formatValue(item, opts, writer, depth, null);
            }
        },
        .tabular => {
            // Format as tabular array: key[N]{fields}:
            //   val1,val2,val3
            //   val4,val5,val6
            const first_obj = arr.items[0].object;
            const delim = opts.delimiter orelse ',';

            // Collect field names in order
            // Use a reasonable max field count to avoid allocation
            const max_fields = 64;
            var fields_buf: [max_fields][]const u8 = undefined;
            var fields_count: usize = 0;

            var it = first_obj.iterator();
            while (it.next()) |entry| {
                if (fields_count >= max_fields) {
                    // Too many fields, fall back to list format
                    try writer.print("[{d}]:\n", .{arr.items.len});
                    for (arr.items) |item| {
                        for (0..depth + 1) |_| {
                            for (0..opts.indent) |_| {
                                try writer.writeByte(' ');
                            }
                        }
                        try writer.writeAll("- ");
                        try formatValue(item, opts, writer, depth + 1, null);
                        try writer.writeByte('\n');
                    }
                    return;
                }
                fields_buf[fields_count] = entry.key_ptr.*;
                fields_count += 1;
            }
            const fields = fields_buf[0..fields_count];

            // Write header: [N]{field1,field2,...}:
            try writer.print("[{d}]{{", .{arr.items.len});
            for (fields, 0..) |field, i| {
                if (i > 0) try writer.writeByte(delim);
                try writer.writeAll(field);
            }
            try writer.writeAll("}:\n");

            // Write rows with indentation
            for (arr.items) |item| {
                // Write indentation
                for (0..depth + 1) |_| {
                    for (0..opts.indent) |_| {
                        try writer.writeByte(' ');
                    }
                }

                // Write row values
                if (item == .object) {
                    const row_obj = item.object;
                    for (fields, 0..) |field, i| {
                        if (i > 0) try writer.writeByte(delim);
                        const field_val = row_obj.get(field) orelse .null;
                        try formatValue(field_val, opts, writer, depth + 1, null);
                    }
                }
                try writer.writeByte('\n');
            }
        },
        .list => {
            // Format as list array: key[N]:
            //   - item1
            //   - item2
            try writer.print("[{d}]:\n", .{arr.items.len});
            for (arr.items) |item| {
                // Write indentation and dash
                for (0..depth + 1) |_| {
                    for (0..opts.indent) |_| {
                        try writer.writeByte(' ');
                    }
                }
                try writer.writeAll("- ");
                try formatValue(item, opts, writer, depth + 1, null);
                try writer.writeByte('\n');
            }
        },
    }
}

/// Formats an object with proper indentation.
fn formatObject(
    obj: Value.Object,
    opts: Options,
    writer: anytype,
    depth: usize,
    parent_key: ?[]const u8,
) anyerror!void {
    if (obj.count() == 0) {
        // Empty object - if at root, output nothing; if nested, just colon
        if (parent_key) |key| {
            try writer.writeAll(key);
            try writer.writeAll(":");
        }
        return;
    }

    var it = obj.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) {
            try writer.writeByte('\n');
        }
        first = false;

        // Write indentation
        for (0..depth) |_| {
            for (0..opts.indent) |_| {
                try writer.writeByte(' ');
            }
        }

        // Write key
        const key = entry.key_ptr.*;
        try writer.writeAll(key);

        // Write value
        const val = entry.value_ptr.*;
        switch (val) {
            .object => |nested_obj| {
                if (nested_obj.count() == 0) {
                    // Empty nested object
                    try writer.writeAll(":");
                } else {
                    try writer.writeAll(":\n");
                    try formatObject(nested_obj, opts, writer, depth + 1, null);
                }
            },
            .array => |arr| {
                if (arr.items.len == 0) {
                    try writer.print("[0]:", .{});
                } else {
                    const format_type = detectArrayFormat(arr.items);
                    switch (format_type) {
                        .inline_format => {
                            try writer.print("[{d}]: ", .{arr.items.len});
                            const delim = opts.delimiter orelse ',';
                            for (arr.items, 0..) |item, i| {
                                if (i > 0) {
                                    try writer.writeByte(delim);
                                }
                                try formatValue(item, opts, writer, depth, null);
                            }
                        },
                        .tabular => {
                            const first_obj = arr.items[0].object;
                            const delim = opts.delimiter orelse ',';

                            // Collect field names in order
                            const max_fields = 64;
                            var fields_buf: [max_fields][]const u8 = undefined;
                            var fields_count: usize = 0;

                            var field_it = first_obj.iterator();
                            while (field_it.next()) |field_entry| {
                                if (fields_count >= max_fields) {
                                    // Too many fields, fall back to list format
                                    try writer.print("[{d}]:\n", .{arr.items.len});
                                    for (arr.items) |item| {
                                        for (0..depth + 1) |_| {
                                            for (0..opts.indent) |_| {
                                                try writer.writeByte(' ');
                                            }
                                        }
                                        try writer.writeAll("- ");
                                        try formatValue(item, opts, writer, depth + 1, null);
                                        try writer.writeByte('\n');
                                    }
                                    return;
                                }
                                fields_buf[fields_count] = field_entry.key_ptr.*;
                                fields_count += 1;
                            }
                            const fields = fields_buf[0..fields_count];

                            try writer.print("[{d}]{{", .{arr.items.len});
                            for (fields, 0..) |field, i| {
                                if (i > 0) try writer.writeByte(delim);
                                try writer.writeAll(field);
                            }
                            try writer.writeAll("}:\n");

                            // Write rows
                            for (arr.items) |item| {
                                // Write indentation
                                for (0..depth + 1) |_| {
                                    for (0..opts.indent) |_| {
                                        try writer.writeByte(' ');
                                    }
                                }

                                // Write row values
                                if (item == .object) {
                                    const row_obj = item.object;
                                    for (fields, 0..) |field, i| {
                                        if (i > 0) try writer.writeByte(delim);
                                        const field_val = row_obj.get(field) orelse .null;
                                        try formatValue(field_val, opts, writer, depth + 1, null);
                                    }
                                }
                                try writer.writeByte('\n');
                            }
                        },
                        .list => {
                            try writer.print("[{d}]:\n", .{arr.items.len});
                            for (arr.items) |item| {
                                // Write indentation and dash
                                for (0..depth + 1) |_| {
                                    for (0..opts.indent) |_| {
                                        try writer.writeByte(' ');
                                    }
                                }
                                try writer.writeAll("- ");
                                try formatValue(item, opts, writer, depth + 1, null);
                                try writer.writeByte('\n');
                            }
                        },
                    }
                }
            },
            else => {
                try writer.writeAll(": ");
                try formatValue(val, opts, writer, depth, null);
            },
        }
    }
}
