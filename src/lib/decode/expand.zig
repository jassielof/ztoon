const std = @import("std");
const types = @import("../types.zig");
const constants = @import("../constants.zig");
const errors = @import("../errors.zig");
const validation = @import("validation.zig");

const Allocator = std.mem.Allocator;
const JsonArray = types.JsonArray;
const JsonObject = types.JsonObject;
const JsonValue = types.JsonValue;

const DOT = constants.dot;

// #region Path expansion (safe)

/// Expands dotted keys into nested objects in safe mode.
///
/// This function recursively traverses a decoded TOON value and expands any keys
/// containing dots (`.`) into nested object structures, provided all segments
/// are valid identifiers.
///
/// Expansion rules:
/// - Keys containing dots are split into segments
/// - All segments must pass `isIdentifierSegment` validation
/// - Non-eligible keys (with special characters) are left as literal dotted keys
/// - Deep merge: When multiple dotted keys expand to the same path, their values are merged if both are objects
/// - Conflict handling:
///   - `strict=true`: Returns error on conflicts (non-object collision)
///   - `strict=false`: LWW (silent overwrite)
pub fn expandPathsSafe(allocator: Allocator, value: JsonValue, quoted_keys: ?std.StringHashMap(void), strict: bool) !JsonValue {
    switch (value) {
        .array => |arr| {
            // Recursively expand array elements
            var expanded_array = JsonArray{};
            errdefer expanded_array.deinit(allocator);

            for (arr.items) |item| {
                const expanded_item = try expandPathsSafe(allocator, item, null, strict);
                try expanded_array.append(allocator, expanded_item);
            }

            return JsonValue{ .array = expanded_array };
        },
        .object => |obj| {
            var expanded_object = JsonObject.init(allocator);
            errdefer expanded_object.deinit();

            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const key_value = entry.value_ptr.*;

                // Skip expansion for keys that were originally quoted
                const is_quoted = if (quoted_keys) |qk| qk.contains(key) else false;

                // Check if key contains dots and should be expanded
                if (std.mem.indexOfScalar(u8, key, DOT) != null and !is_quoted) {
                    var segments = std.ArrayList([]const u8){};
                    defer segments.deinit(allocator);

                    var segment_iter = std.mem.splitScalar(u8, key, DOT);
                    while (segment_iter.next()) |segment| {
                        try segments.append(allocator, segment);
                    }

                    // Validate all segments are identifiers
                    var all_valid = true;
                    for (segments.items) |segment| {
                        if (!validation.isIdentifierSegment(segment)) {
                            all_valid = false;
                            break;
                        }
                    }

                    if (all_valid) {
                        // Expand this dotted key
                        const expanded_value = try expandPathsSafe(allocator, key_value, null, strict);
                        try insertPathSafe(allocator, &expanded_object, segments.items, expanded_value, strict);
                        continue;
                    }
                }

                // Not expandable - keep as literal key, but still recursively expand the value
                const expanded_value = try expandPathsSafe(allocator, key_value, null, strict);

                // Check for conflicts with already-expanded keys
                if (expanded_object.getPtr(key)) |conflicting_value| {
                    // If both are objects, try to merge them
                    if (canMerge(conflicting_value.*, expanded_value)) {
                        try mergeObjects(allocator, &conflicting_value.object, expanded_value.object, strict);
                    } else {
                        // Conflict: incompatible types
                        if (strict) {
                            return errors.DecodeError.PathExpansionConflict;
                        }
                        // Non-strict: overwrite (LWW)
                        try expanded_object.put(key, expanded_value);
                    }
                } else {
                    // No conflict - insert directly
                    try expanded_object.put(key, expanded_value);
                }
            }

            return JsonValue{ .object = expanded_object };
        },
        .primitive => {
            // Primitive value - return as-is
            return value;
        },
    }
}

/// Inserts a value at a nested path, creating intermediate objects as needed.
///
/// This function walks the segment path, creating nested objects as needed.
/// When an existing value is encountered:
/// - If both are objects: deep merge (continue insertion)
/// - If values differ: conflict
///   - strict=true: return error
///   - strict=false: overwrite with new value (LWW)
fn insertPathSafe(
    allocator: Allocator,
    target: *JsonObject,
    segments: []const []const u8,
    value: JsonValue,
    strict: bool,
) !void {
    var current_node = target;

    // Walk to the penultimate segment, creating objects as needed
    for (segments[0 .. segments.len - 1]) |current_segment| {
        if (current_node.getPtr(current_segment)) |segment_value| {
            switch (segment_value.*) {
                .object => |*obj| {
                    // Continue into existing object
                    current_node = obj;
                },
                else => {
                    // Conflict: existing value is not an object
                    if (strict) {
                        return errors.DecodeError.PathExpansionConflict;
                    }
                    // Non-strict: overwrite with new object
                    const new_obj = JsonObject.init(allocator);
                    try current_node.put(current_segment, JsonValue{ .object = new_obj });
                    current_node = &(current_node.getPtr(current_segment).?.object);
                },
            }
        } else {
            // Create new intermediate object
            const new_obj = JsonObject.init(allocator);
            try current_node.put(current_segment, JsonValue{ .object = new_obj });
            current_node = &(current_node.getPtr(current_segment).?.object);
        }
    }

    // Insert at the final segment
    const last_seg = segments[segments.len - 1];

    if (current_node.getPtr(last_seg)) |destination_value| {
        if (canMerge(destination_value.*, value)) {
            // Both are objects - deep merge
            try mergeObjects(allocator, &destination_value.object, value.object, strict);
        } else {
            // Conflict: incompatible types
            if (strict) {
                return errors.DecodeError.PathExpansionConflict;
            }
            // Non-strict: overwrite (LWW)
            try current_node.put(last_seg, value);
        }
    } else {
        // No conflict - insert directly
        try current_node.put(last_seg, value);
    }
}

/// Deep merges properties from source into target.
///
/// For each key in source:
/// - If key doesn't exist in target: copy it
/// - If both values are objects: recursively merge
/// - Otherwise: conflict (strict returns error, non-strict overwrites)
fn mergeObjects(
    allocator: Allocator,
    target: *JsonObject,
    source: JsonObject,
    strict: bool,
) !void {
    var iter = source.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const source_value = entry.value_ptr.*;

        if (target.getPtr(key)) |target_value| {
            if (canMerge(target_value.*, source_value)) {
                // Both are objects - recursively merge
                try mergeObjects(allocator, &target_value.object, source_value.object, strict);
            } else {
                // Conflict: incompatible types
                if (strict) {
                    return errors.DecodeError.PathExpansionConflict;
                }
                // Non-strict: overwrite (LWW)
                try target.put(key, source_value);
            }
        } else {
            // Key doesn't exist in target - copy it
            try target.put(key, source_value);
        }
    }
}

// #endregion

fn canMerge(a: JsonValue, b: JsonValue) bool {
    return isJsonObject(a) and isJsonObject(b);
}

fn isJsonObject(value: JsonValue) bool {
    return switch (value) {
        .object => true,
        else => false,
    };
}
