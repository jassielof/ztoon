//! Main encoding logic for arrays and objects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../Value.zig").Value;
const Options = @import("Options.zig");
const normalize = @import("normalize.zig");
const primitives = @import("primitives.zig");
const folding = @import("folding.zig");

const LIST_ITEM_PREFIX = "- ";

/// Encodes a Value to TOON format, writing lines to the writer.
pub fn encodeValue(
    value: Value,
    options: Options,
    writer: anytype,
    depth: usize,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error || error{InvalidType})!void {
    if (normalize.isJsonPrimitive(value)) {
        // Primitives at root level are returned as a single line
        const encoded = primitives.encodePrimitive(value, options.delimiter orelse ',', allocator) catch |err| switch (err) {
            error.InvalidType => return error.OutOfMemory, // Should never happen
            else => |e| return e,
        };
        defer allocator.free(encoded);
        if (encoded.len > 0) {
            try writer.writeAll(encoded);
        }
        return;
    }

    if (normalize.isJsonArray(value)) {
        try encodeArrayLines(null, value.array, depth, options, writer, allocator);
    } else if (normalize.isJsonObject(value)) {
        try encodeObjectLines(value.object, depth, options, writer, allocator, null, null, null);
    }
}

/// Encodes object lines with proper indentation.
fn encodeObjectLines(
    obj: Value.Object,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
    root_literal_keys: ?std.StringHashMap(void),
    path_prefix: ?[]const u8,
    remaining_depth: ?usize,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    // Collect all keys for sibling iteration
    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (keys.items) |key| {
            allocator.free(key);
        }
        keys.deinit();
    }

    var it = obj.iterator();
    while (it.next()) |entry| {
        try keys.append(try allocator.dupe(u8, entry.key_ptr.*));
    }

    // At root level (depth 0), collect all literal dotted keys for collision checking
    var root_literal_keys_map: ?std.StringHashMap(void) = root_literal_keys;
    if (depth == 0 and root_literal_keys_map == null) {
        var literal_map = std.StringHashMap(void).init(allocator);
        errdefer literal_map.deinit();
        for (keys.items) |key| {
            if (std.mem.indexOfScalar(u8, key, '.') != null) {
                try literal_map.put(key, {});
            }
        }
        root_literal_keys_map = literal_map;
    }

    const effective_flatten_depth = remaining_depth orelse options.flatten_depth;

    for (keys.items) |key| {
        const val = obj.get(key).?;
        try encodeKeyValuePairLines(
            key,
            val,
            depth,
            options,
            writer,
            keys.items,
            root_literal_keys_map,
            path_prefix,
            effective_flatten_depth,
            allocator,
        );
    }
}

/// Encodes a key-value pair.
fn encodeKeyValuePairLines(
    key: []const u8,
    value: Value,
    depth: usize,
    options: Options,
    writer: anytype,
    siblings: []const []const u8,
    root_literal_keys: ?std.StringHashMap(void),
    path_prefix: ?[]const u8,
    flatten_depth: ?usize,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    const current_path = if (path_prefix) |prefix|
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, key })
    else
        try allocator.dupe(u8, key);
    defer allocator.free(current_path);

    // Attempt key folding when enabled
    if (options.key_folding == .safe) {
        const fold_result = try folding.tryFoldKeyChain(
            key,
            value,
            siblings,
            .{
                .key_folding = switch (options.key_folding) {
                    .off => .off,
                    .safe => .safe,
                },
                .flatten_depth = options.flatten_depth,
            },
            root_literal_keys,
            path_prefix,
            flatten_depth,
            allocator,
        );

        if (fold_result) |fold| {
            defer allocator.free(fold.folded_key);
            const encoded_folded_key = try primitives.encodeKey(fold.folded_key, allocator);
            defer allocator.free(encoded_folded_key);

            // Case 1: Fully folded to a leaf value
            if (fold.remainder == null) {
                if (normalize.isJsonPrimitive(fold.leaf_value)) {
                    const encoded_value = primitives.encodePrimitive(fold.leaf_value, options.delimiter orelse ',', allocator) catch |err| switch (err) {
                        error.InvalidType => return error.OutOfMemory, // Should never happen
                        else => |e| return e,
                    };
                    defer allocator.free(encoded_value);
                    try writeIndentedLine(depth, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ encoded_folded_key, encoded_value }), options.indent, writer, allocator);
                    return;
                } else if (normalize.isJsonArray(fold.leaf_value)) {
                    try encodeArrayLines(fold.folded_key, fold.leaf_value.array, depth, options, writer, allocator);
                    return;
                } else if (normalize.isJsonObject(fold.leaf_value) and normalize.isEmptyObject(fold.leaf_value.object)) {
                    try writeIndentedLine(depth, try std.fmt.allocPrint(allocator, "{s}:", .{encoded_folded_key}), options.indent, writer, allocator);
                    return;
                }
            }

            // Case 2: Partially folded with a tail object
            if (fold.remainder) |remainder| {
                defer remainder.deinit(allocator);
                if (normalize.isJsonObject(remainder)) {
                    try writeIndentedLine(depth, try std.fmt.allocPrint(allocator, "{s}:", .{encoded_folded_key}), options.indent, writer, allocator);
                    // Calculate remaining depth budget
                    const remaining_depth_budget = if (flatten_depth) |fd|
                        if (fold.segment_count < fd) fd - fold.segment_count else 0
                    else
                        null;
                    const folded_path = if (path_prefix) |prefix|
                        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, fold.folded_key })
                    else
                        try allocator.dupe(u8, fold.folded_key);
                    defer allocator.free(folded_path);
                    try encodeObjectLines(remainder.object, depth + 1, options, writer, allocator, root_literal_keys, folded_path, remaining_depth_budget);
                    return;
                }
            }
        }
    }

    const encoded_key = try primitives.encodeKey(key, allocator);
    defer allocator.free(encoded_key);

    if (normalize.isJsonPrimitive(value)) {
        const encoded_value = primitives.encodePrimitive(value, options.delimiter orelse ',', allocator) catch |err| switch (err) {
            error.InvalidType => return error.OutOfMemory, // Should never happen
            else => |e| return e,
        };
        defer allocator.free(encoded_value);
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ encoded_key, encoded_value });
        defer allocator.free(line);
        try writeIndentedLine(depth, line, options.indent, writer, allocator);
    } else if (normalize.isJsonArray(value)) {
        try encodeArrayLines(key, value.array, depth, options, writer, allocator);
    } else if (normalize.isJsonObject(value)) {
        const line = try std.fmt.allocPrint(allocator, "{s}:", .{encoded_key});
        defer allocator.free(line);
        try writeIndentedLine(depth, line, options.indent, writer, allocator);
        if (!normalize.isEmptyObject(value.object)) {
            try encodeObjectLines(value.object, depth + 1, options, writer, allocator, root_literal_keys, current_path, flatten_depth);
        }
    }
}

/// Encodes array lines, choosing the best format (inline, tabular, or list).
fn encodeArrayLines(
    key: ?[]const u8,
    arr: Value.Array,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    if (arr.items.len == 0) {
        const header = try primitives.formatHeader(0, allocator, .{
            .key = key,
            .delimiter = options.delimiter orelse ',',
        });
        defer allocator.free(header);
        try writeIndentedLine(depth, header, options.indent, writer, allocator);
        return;
    }

    // Primitive array
    if (normalize.isArrayOfPrimitives(arr)) {
        const array_line = try encodeInlineArrayLine(arr.items, options.delimiter orelse ',', key, allocator);
        defer allocator.free(array_line);
        try writeIndentedLine(depth, array_line, options.indent, writer, allocator);
        return;
    }

    // Array of arrays (all primitives)
    if (normalize.isArrayOfArrays(arr)) {
        const all_primitive_arrays = blk: {
            for (arr.items) |item| {
                if (!normalize.isArrayOfPrimitives(item.array)) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        if (all_primitive_arrays) {
            try encodeArrayOfArraysAsListItemsLines(key, arr.items, depth, options, writer, allocator);
            return;
        }
    }

    // Array of objects
    if (normalize.isArrayOfObjects(arr)) {
        const header = try extractTabularHeader(arr.items, allocator);
        if (header) |h| {
            defer {
                for (h.fields.items) |field| {
                    allocator.free(field);
                }
                h.fields.deinit();
                allocator.destroy(h);
            }
            try encodeArrayOfObjectsAsTabularLines(key, arr.items, h.fields.items, depth, options, writer, allocator);
            return;
        }
    }

    // Mixed array: fallback to expanded format
    try encodeMixedArrayAsListItemsLines(key, arr.items, depth, options, writer, allocator);
}

/// Encodes an inline primitive array.
fn encodeInlineArrayLine(
    values: []const Value,
    delimiter: u8,
    prefix: ?[]const u8,
    allocator: Allocator,
) Allocator.Error![]const u8 {
    const header = try primitives.formatHeader(values.len, allocator, .{
        .key = prefix,
        .delimiter = delimiter,
    });
    defer allocator.free(header);

    if (values.len == 0) {
        return try allocator.dupe(u8, header);
    }

    const joined = try primitives.encodeAndJoinPrimitives(values, delimiter, allocator);
    defer allocator.free(joined);

    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ header, joined });
}

/// Encodes array of arrays as list items.
fn encodeArrayOfArraysAsListItemsLines(
    prefix: ?[]const u8,
    values: []const Value,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    const header = try primitives.formatHeader(values.len, allocator, .{
        .key = prefix,
        .delimiter = options.delimiter orelse ',',
    });
    defer allocator.free(header);
    try writeIndentedLine(depth, header, options.indent, writer, allocator);

    for (values) |arr| {
        if (normalize.isArrayOfPrimitives(arr.array)) {
            const array_line = try encodeInlineArrayLine(arr.array.items, options.delimiter orelse ',', null, allocator);
            defer allocator.free(array_line);
            try writeIndentedListItem(depth + 1, array_line, options.indent, writer, allocator);
        }
    }
}

/// Tabular header extraction result.
const TabularHeader = struct {
    fields: std.array_list.Managed([]const u8),
};

/// Extracts tabular header from array of objects.
fn extractTabularHeader(
    rows: []const Value,
    allocator: Allocator,
) Allocator.Error!?*TabularHeader {
    if (rows.len == 0) return null;

    const first_row = rows[0];
    if (first_row != .object) return null;

    const first_obj = first_row.object;
    if (first_obj.count() == 0) return null;

    // Collect first object's keys in order
    var fields = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (fields.items) |field| {
            allocator.free(field);
        }
        fields.deinit();
    }

    var it = first_obj.iterator();
    while (it.next()) |entry| {
        // Check that first row's values are also primitives
        if (!normalize.isJsonPrimitive(entry.value_ptr.*)) {
            return null;
        }
        try fields.append(try allocator.dupe(u8, entry.key_ptr.*));
    }

    const first_fields = fields.items;

    // Check if all rows are tabular
    for (rows[1..]) |row| {
        if (row != .object) return null;
        const obj = row.object;

        // Check field count matches
        if (obj.count() != first_fields.len) {
            return null;
        }

        // Check all fields exist and are primitives
        for (first_fields) |field| {
            const val = obj.get(field) orelse return null;
            if (!normalize.isJsonPrimitive(val)) {
                return null;
            }
        }
    }

    const header = try allocator.create(TabularHeader);
    header.fields = fields;
    return header;
}

/// Encodes array of objects as tabular lines.
fn encodeArrayOfObjectsAsTabularLines(
    prefix: ?[]const u8,
    rows: []const Value,
    header: []const []const u8,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    const formatted_header = try primitives.formatHeader(rows.len, allocator, .{
        .key = prefix,
        .fields = header,
        .delimiter = options.delimiter orelse ',',
    });
    defer allocator.free(formatted_header);
    try writeIndentedLine(depth, formatted_header, options.indent, writer, allocator);

    try writeTabularRowsLines(rows, header, depth + 1, options, writer, allocator);
}

/// Writes tabular row lines.
/// Assumes all values are primitives (checked by extractTabularHeader).
fn writeTabularRowsLines(
    rows: []const Value,
    header: []const []const u8,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    for (rows) |row| {
        if (row != .object) continue;
        const row_obj = row.object;

        var values = std.array_list.Managed(Value).init(allocator);
        defer values.deinit();
        for (header) |field| {
            const val = row_obj.get(field) orelse Value{ .null = {} };
            // Ensure value is primitive (should be guaranteed by extractTabularHeader, but double-check for safety)
            if (!normalize.isJsonPrimitive(val)) {
                // This should never happen if extractTabularHeader worked correctly
                // But if it does, skip this row or handle gracefully
                continue;
            }
            try values.append(val);
        }

        if (values.items.len == header.len) {
            // All values should be primitives (checked by extractTabularHeader)
            // encodeAndJoinPrimitives will handle any errors
            const joined = primitives.encodeAndJoinPrimitives(values.items, options.delimiter orelse ',', allocator) catch |err| {
                // If encoding fails (shouldn't happen for primitives), skip this row
                _ = err catch {};
                continue;
            };
            defer allocator.free(joined);
            try writeIndentedLine(depth, joined, options.indent, writer, allocator);
        }
    }
}

/// Encodes mixed array as list items.
fn encodeMixedArrayAsListItemsLines(
    prefix: ?[]const u8,
    items: []const Value,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    const header = try primitives.formatHeader(items.len, allocator, .{
        .key = prefix,
        .delimiter = options.delimiter orelse ',',
    });
    defer allocator.free(header);
    try writeIndentedLine(depth, header, options.indent, writer, allocator);

    for (items) |item| {
        try encodeListItemValueLines(item, depth + 1, options, writer, allocator);
    }
}

/// Encodes a list item value.
fn encodeListItemValueLines(
    value: Value,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    if (normalize.isJsonPrimitive(value)) {
        const encoded = primitives.encodePrimitive(value, options.delimiter orelse ',', allocator) catch |err| switch (err) {
            error.InvalidType => return error.OutOfMemory, // Should never happen
            else => |e| return e,
        };
        defer allocator.free(encoded);
        try writeIndentedListItem(depth, encoded, options.indent, writer, allocator);
    } else if (normalize.isJsonArray(value)) {
        if (normalize.isArrayOfPrimitives(value.array)) {
            const array_line = try encodeInlineArrayLine(value.array.items, options.delimiter orelse ',', null, allocator);
            defer allocator.free(array_line);
            try writeIndentedListItem(depth, array_line, options.indent, writer, allocator);
        } else {
            const header = try primitives.formatHeader(value.array.items.len, allocator, .{
                .delimiter = options.delimiter orelse ',',
            });
            defer allocator.free(header);
            try writeIndentedListItem(depth, header, options.indent, writer, allocator);
            for (value.array.items) |item| {
                try encodeListItemValueLines(item, depth + 1, options, writer, allocator);
            }
        }
    } else if (normalize.isJsonObject(value)) {
        try encodeObjectAsListItemLines(value.object, depth, options, writer, allocator);
    }
}

/// Encodes an object as a list item.
fn encodeObjectAsListItemLines(
    obj: Value.Object,
    depth: usize,
    options: Options,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    if (normalize.isEmptyObject(obj)) {
        try writeIndentedLine(depth, "-", options.indent, writer, allocator);
        return;
    }

    // Collect entries
    var entries = std.array_list.Managed(struct { []const u8, Value }).init(allocator);
    defer {
        for (entries.items) |entry| {
            allocator.free(entry[0]);
        }
        entries.deinit();
    }

    var it = obj.iterator();
    while (it.next()) |entry| {
        try entries.append(.{ try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.* });
    }

    if (entries.items.len == 0) return;

    const first_entry = entries.items[0];
    const first_key = first_entry[0];
    const first_value = first_entry[1];
    const rest_entries = entries.items[1..];

    // Check if first field is a tabular array
    if (normalize.isJsonArray(first_value) and normalize.isArrayOfObjects(first_value.array)) {
        const header = try extractTabularHeader(first_value.array.items, allocator);
        if (header) |h| {
            defer {
                for (h.fields.items) |field| {
                    allocator.free(field);
                }
                h.fields.deinit();
                allocator.destroy(h);
            }
            // Tabular array as first field
            const formatted_header = try primitives.formatHeader(first_value.array.items.len, allocator, .{
                .key = first_key,
                .fields = h.fields.items,
                .delimiter = options.delimiter orelse ',',
            });
            defer allocator.free(formatted_header);
            try writeIndentedListItem(depth, formatted_header, options.indent, writer, allocator);
            try writeTabularRowsLines(first_value.array.items, h.fields.items, depth + 2, options, writer, allocator);

            if (rest_entries.len > 0) {
                // Create rest object
                var rest_obj = Value.Object.init(allocator);
                errdefer {
                    var rest_it = rest_obj.iterator();
                    while (rest_it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                    }
                    rest_obj.deinit();
                }
                for (rest_entries) |entry| {
                    try rest_obj.put(try allocator.dupe(u8, entry[0]), entry[1]);
                }
                try encodeObjectLines(rest_obj, depth + 1, options, writer, allocator, null, null, null);
            }
            return;
        }
    }

    const encoded_key = try primitives.encodeKey(first_key, allocator);
    defer allocator.free(encoded_key);

    if (normalize.isJsonPrimitive(first_value)) {
        const encoded_value = primitives.encodePrimitive(first_value, options.delimiter orelse ',', allocator) catch |err| switch (err) {
            error.InvalidType => return error.OutOfMemory, // Should never happen
            else => |e| return e,
        };
        defer allocator.free(encoded_value);
        try writeIndentedListItem(depth, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ encoded_key, encoded_value }), options.indent, writer, allocator);
    } else if (normalize.isJsonArray(first_value)) {
        if (first_value.array.items.len == 0) {
            const header_str = try primitives.formatHeader(0, allocator, .{
                .delimiter = options.delimiter orelse ',',
            });
            defer allocator.free(header_str);
            try writeIndentedListItem(depth, try std.fmt.allocPrint(allocator, "{s}{s}", .{ encoded_key, header_str }), options.indent, writer, allocator);
        } else if (normalize.isArrayOfPrimitives(first_value.array)) {
            const array_line = try encodeInlineArrayLine(first_value.array.items, options.delimiter orelse ',', null, allocator);
            defer allocator.free(array_line);
            try writeIndentedListItem(depth, try std.fmt.allocPrint(allocator, "{s}{s}", .{ encoded_key, array_line }), options.indent, writer, allocator);
        } else {
            const header_str = try primitives.formatHeader(first_value.array.items.len, allocator, .{
                .delimiter = options.delimiter orelse ',',
            });
            defer allocator.free(header_str);
            try writeIndentedListItem(depth, try std.fmt.allocPrint(allocator, "{s}{s}", .{ encoded_key, header_str }), options.indent, writer, allocator);

            for (first_value.array.items) |item| {
                try encodeListItemValueLines(item, depth + 2, options, writer, allocator);
            }
        }
    } else if (normalize.isJsonObject(first_value)) {
        try writeIndentedListItem(depth, try std.fmt.allocPrint(allocator, "{s}:", .{encoded_key}), options.indent, writer, allocator);
        if (!normalize.isEmptyObject(first_value.object)) {
            try encodeObjectLines(first_value.object, depth + 2, options, writer, allocator, null, null, null);
        }
    }

    if (rest_entries.len > 0) {
        // Create rest object
        var rest_obj = Value.Object.init(allocator);
        errdefer {
            var rest_it = rest_obj.iterator();
            while (rest_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            rest_obj.deinit();
        }
        for (rest_entries) |entry| {
            try rest_obj.put(try allocator.dupe(u8, entry[0]), entry[1]);
        }
        try encodeObjectLines(rest_obj, depth + 1, options, writer, allocator, null, null, null);
    }
}

/// Writes an indented line.
fn writeIndentedLine(
    depth: usize,
    content: []const u8,
    indent_size: usize,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    _ = allocator;
    const indentation = depth * indent_size;
    for (0..indentation) |_| {
        try writer.writeByte(' ');
    }
    try writer.writeAll(content);
    try writer.writeByte('\n');
}

/// Writes an indented list item.
fn writeIndentedListItem(
    depth: usize,
    content: []const u8,
    indent_size: usize,
    writer: anytype,
    allocator: Allocator,
) (@TypeOf(writer).Error || Allocator.Error)!void {
    _ = allocator;
    const indentation = depth * indent_size;
    for (0..indentation) |_| {
        try writer.writeByte(' ');
    }
    try writer.writeAll(LIST_ITEM_PREFIX);
    try writer.writeAll(content);
}
