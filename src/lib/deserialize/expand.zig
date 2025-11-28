//! Path expansion for dotted keys in TOON
//!
//! When `expandPaths="safe"`, dotted keys like `a.b.c` are expanded into
//! nested object structures `{a: {b: {c: value}}}`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ValueMod = @import("../Value.zig");
const Value = ValueMod.Value;

/// Check if a key segment is a valid identifier for safe expansion.
/// Valid identifiers start with a letter or underscore, followed by
/// letters, digits, or underscores (no dots).
pub fn isIdentifierSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;

    // First character must be letter or underscore
    const first = segment[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    // Rest must be alphanumeric or underscore
    for (segment[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    return true;
}

/// Check if a key should be expanded (contains dots and all segments are valid identifiers)
pub fn shouldExpandKey(key: []const u8) bool {
    // Must contain at least one dot
    if (std.mem.indexOfScalar(u8, key, '.') == null) return false;

    // Split by dots and check each segment
    var iter = std.mem.splitScalar(u8, key, '.');
    while (iter.next()) |segment| {
        if (!isIdentifierSegment(segment)) return false;
    }

    return true;
}

/// Expand dotted keys in a Value into nested objects.
/// Returns a new Value with expanded paths (caller owns the memory).
pub fn expandPathsSafe(value: Value, allocator: Allocator, strict: bool) !Value {
    return switch (value) {
        .null, .bool, .integer, .float, .number_string, .string => value.clone(allocator),
        .array => |arr| {
            var new_items = std.array_list.Managed(Value).init(allocator);
            errdefer {
                for (new_items.items) |*item| {
                    item.deinit(allocator);
                }
                new_items.deinit();
            }

            for (arr.items) |item| {
                const expanded = try expandPathsSafe(item, allocator, strict);
                try new_items.append(expanded);
            }

            const owned_slice = try new_items.toOwnedSlice();
            const result_arr = std.ArrayList(Value){ .items = owned_slice, .capacity = owned_slice.len };
            return .{ .array = result_arr };
        },
        .object => |obj| {
            var result = Value.Object.init(allocator);
            errdefer {
                var it = result.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                result.deinit();
            }

            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                // Recursively expand the value first
                const expanded_value = try expandPathsSafe(val, allocator, strict);
                errdefer expanded_value.deinit(allocator);

                // Check if key should be expanded
                if (shouldExpandKey(key)) {
                    // Split into segments and insert at path
                    try insertPathSafe(&result, key, expanded_value, allocator, strict);
                } else {
                    // Keep as literal key - check for conflicts with existing keys
                    if (result.getPtr(key)) |existing_ptr| {
                        if (canMerge(existing_ptr.*, expanded_value)) {
                            // Merge objects
                            try mergeObjects(existing_ptr, expanded_value, allocator, strict);
                            var mutable_expanded = expanded_value;
                            mutable_expanded.deinit(allocator);
                        } else {
                            if (strict) {
                                return error.PathExpansionConflict;
                            }
                            // LWW - overwrite
                            existing_ptr.deinit(allocator);
                            existing_ptr.* = expanded_value;
                        }
                    } else {
                        const new_key = try allocator.dupe(u8, key);
                        try result.put(new_key, expanded_value);
                    }
                }
            }

            return .{ .object = result };
        },
    };
}

/// Insert a value at a dotted path, creating intermediate objects as needed.
fn insertPathSafe(
    target: *Value.Object,
    dotted_key: []const u8,
    value: Value,
    allocator: Allocator,
    strict: bool,
) !void {
    // Split the key into segments
    var segments = std.array_list.Managed([]const u8).init(allocator);
    defer segments.deinit();

    var iter = std.mem.splitScalar(u8, dotted_key, '.');
    while (iter.next()) |seg| {
        try segments.append(seg);
    }

    if (segments.items.len == 0) return;

    // Walk to the penultimate segment, creating objects as needed
    var current_obj = target;
    for (segments.items[0 .. segments.items.len - 1]) |segment| {
        // Use getPtr to get a mutable pointer
        if (current_obj.getPtr(segment)) |existing_ptr| {
            switch (existing_ptr.*) {
                .object => |*obj| {
                    current_obj = obj;
                },
                else => {
                    if (strict) {
                        return error.PathExpansionConflict;
                    }
                    // Non-strict: overwrite with new object
                    existing_ptr.deinit(allocator);
                    existing_ptr.* = .{ .object = Value.Object.init(allocator) };
                    current_obj = &existing_ptr.object;
                },
            }
        } else {
            // Create new intermediate object
            const seg_key = try allocator.dupe(u8, segment);
            errdefer allocator.free(seg_key);
            const new_obj = Value.Object.init(allocator);
            try current_obj.put(seg_key, .{ .object = new_obj });
            current_obj = &current_obj.getPtr(segment).?.object;
        }
    }

    // Insert at the final segment
    const last_seg = segments.items[segments.items.len - 1];

    if (current_obj.getPtr(last_seg)) |existing_ptr| {
        if (canMerge(existing_ptr.*, value)) {
            // Deep merge
            try mergeObjects(existing_ptr, value, allocator, strict);
            var mutable_value = value;
            mutable_value.deinit(allocator);
        } else {
            if (strict) {
                return error.PathExpansionConflict;
            }
            // LWW - overwrite
            existing_ptr.deinit(allocator);
            existing_ptr.* = value;
        }
    } else {
        const last_key = try allocator.dupe(u8, last_seg);
        try current_obj.put(last_key, value);
    }
}

/// Check if two values can be merged (both are objects)
fn canMerge(a: Value, b: Value) bool {
    return a == .object and b == .object;
}

/// Deep merge source object into target object
fn mergeObjects(
    target: *Value,
    source: Value,
    allocator: Allocator,
    strict: bool,
) !void {
    if (target.* != .object or source != .object) return;

    var source_iter = source.object.iterator();
    while (source_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const source_val = entry.value_ptr.*;

        const new_key = try allocator.dupe(u8, key);
        errdefer allocator.free(new_key);

        if (target.object.getPtr(key)) |existing_ptr| {
            allocator.free(new_key);
            if (canMerge(existing_ptr.*, source_val)) {
                // Recursively merge
                try mergeObjects(existing_ptr, source_val, allocator, strict);
            } else {
                if (strict) {
                    return error.PathExpansionConflict;
                }
                // LWW - overwrite
                existing_ptr.deinit(allocator);
                existing_ptr.* = try source_val.clone(allocator);
            }
        } else {
            // Copy the value
            const cloned = try source_val.clone(allocator);
            try target.object.put(new_key, cloned);
        }
    }
}

// Tests
test "isIdentifierSegment" {
    const testing = std.testing;

    try testing.expect(isIdentifierSegment("abc"));
    try testing.expect(isIdentifierSegment("_abc"));
    try testing.expect(isIdentifierSegment("abc123"));
    try testing.expect(isIdentifierSegment("_123"));
    try testing.expect(isIdentifierSegment("A"));
    try testing.expect(isIdentifierSegment("_"));

    try testing.expect(!isIdentifierSegment(""));
    try testing.expect(!isIdentifierSegment("123abc"));
    try testing.expect(!isIdentifierSegment("a.b"));
    try testing.expect(!isIdentifierSegment("a-b"));
    try testing.expect(!isIdentifierSegment("a b"));
}

test "shouldExpandKey" {
    const testing = std.testing;

    try testing.expect(shouldExpandKey("a.b"));
    try testing.expect(shouldExpandKey("a.b.c"));
    try testing.expect(shouldExpandKey("data.meta.items"));

    try testing.expect(!shouldExpandKey("abc")); // No dot
    try testing.expect(!shouldExpandKey("a-b.c")); // Invalid segment
    try testing.expect(!shouldExpandKey("123.abc")); // Invalid first segment
}

test "conflict detection - object vs primitive" {
    const testing = std.testing;

    // Create object with both "a.b" and "a" keys
    var obj = Value.Object.init(testing.allocator);
    defer obj.deinit();

    const key1 = try testing.allocator.dupe(u8, "a.b");
    try obj.put(key1, .{ .integer = 1 });

    const key2 = try testing.allocator.dupe(u8, "a");
    try obj.put(key2, .{ .integer = 2 });

    // Try to expand with strict mode - should fail
    const result = expandPathsSafe(.{ .object = obj }, testing.allocator, true);
    try testing.expectError(error.PathExpansionConflict, result);
}
