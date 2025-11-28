//! TOONZ dynamic value type, similar to std.json.Value
//! Represents any TOON value at runtime with dynamic typing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A TOONZ value that can represent any TOON data type.
/// This is similar to std.json.Value but for the TOON format.
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    number_string: []const u8,
    string: []const u8,
    array: Array,
    object: Object,

    pub const Array = std.ArrayList(Value);
    pub const Object = std.StringHashMap(Value);

    /// Recursively deallocate all memory associated with this value.
    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .null, .bool, .integer, .float => {},
            .number_string, .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr.items) |item| {
                    item.deinit(allocator);
                }
                var mutable_arr = arr;
                mutable_arr.deinit(allocator);
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                var mutable_obj = obj;
                mutable_obj.deinit();
            },
        }
    }

    /// Create a deep copy of this value.
    pub fn clone(self: Value, allocator: Allocator) Allocator.Error!Value {
        return switch (self) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_array = std.array_list.Managed(Value).init(allocator);
                errdefer {
                    for (new_array.items) |*item| {
                        item.deinit(allocator);
                    }
                    new_array.deinit();
                }
                try new_array.ensureTotalCapacity(arr.items.len);
                for (arr.items) |item| {
                    new_array.appendAssumeCapacity(try item.clone(allocator));
                }
                const owned_slice = try new_array.toOwnedSlice();
                const result_arr = Array{ .items = owned_slice, .capacity = owned_slice.len };
                return .{ .array = result_arr };
            },
            .object => |obj| {
                var new_object = Object.init(allocator);
                errdefer {
                    var it = new_object.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    new_object.deinit();
                }
                try new_object.ensureTotalCapacity(obj.count());
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try entry.value_ptr.clone(allocator);
                    new_object.putAssumeCapacity(key, value);
                }
                return .{ .object = new_object };
            },
        };
    }
};

/// Parsed TOONZ value with owned memory
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: Parsed) void {
        self.arena.deinit();
    }
};
