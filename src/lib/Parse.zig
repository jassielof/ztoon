//! Writes TOON formatted data to a stream
const assert = std.debug.assert;

const std = @import("std");
const Parse = @This();
const Writer = std.Io.Writer;
const ArenaAllocator = std.heap.ArenaAllocator;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
pub const Scanner = @import("Scanner.zig");
const Context = @import("parser/Context.zig");
const Options = @import("parser/Options.zig");
const value = @import("parser/types/value.zig").parseValue;
const parseFieldValue = @import("parser/types/value.zig").parseFieldValue;
const fieldMatches = @import("utils/field.zig").fieldMatches;

fn parseTabularRow(
    comptime T: type,
    row: []const u8,
    field_names: []const []const u8,
    allocator: Allocator,
) !T {
    const struct_info = @typeInfo(T).@"struct";

    var result: T = undefined;

    // Split row by comma (TODO: support other delimiters)
    var values = std.array_list.Managed([]const u8).init(allocator);
    defer values.deinit();

    var value_iter = std.mem.splitScalar(u8, row, ',');
    while (value_iter.next()) |val| {
        try values.append(std.mem.trim(u8, val, &std.ascii.whitespace));
    }

    if (values.items.len != field_names.len) {
        return error.SyntaxError;
    }

    // Match each field name to struct field and parse value
    for (field_names, values.items) |toon_field, val| {
        var matched = false;

        inline for (struct_info.fields) |field| {
            if (try fieldMatches(toon_field, field.name, allocator)) {
                const parsed_value = try parseFieldValue(field.type, val, allocator);
                @field(result, field.name) = parsed_value;
                matched = true;
                break;
            }
        }

        if (!matched) return error.UnknownField;
    }

    return result;
}

fn internal(comptime T: type, allocator: Allocator, source: anytype, options: Options) !T {
    var scanner = try Scanner.init(allocator, source, options.indent);
    defer scanner.deinit();

    var ctx = Context{
        .allocator = allocator,
        .options = options,
        .depth = 0,
    };

    return try value(T, &scanner, 0, &ctx);
}

pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            const child_allocator = self.arena.child_allocator;
            self.arena.deinit();
            child_allocator.destroy(self.arena);
        }
    };
}

/// Parse a TOON document from an input into a typed Zig value.
pub fn fromSlice(comptime T: type, allocator: Allocator, input: []const u8, options: Options) !Parsed(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    const val = try internal(T, arena_allocator, input, options);
    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = arena;
    return Parsed(T){
        .value = val,
        .arena = arena_ptr,
    };
}
