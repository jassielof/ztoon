const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("../../Scanner.zig");
const Context = @import("../Context.zig");
const parseFieldValue = @import("value.zig").parseFieldValue;
const parsePrimitiveValue = @import("value.zig").parsePrimitiveValue;
const fieldMatches = @import("../..//utils/field.zig").fieldMatches;
pub fn parseTabularArray(
    comptime T: type,
    header: ArrayHeader,
    scanner: *Scanner,
    base_indent: usize,
    allocator: Allocator,
) ![]T {
    const fields = header.fields orelse return error.SyntaxError;

    // Verify T is a struct
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.TypeMismatch;

    var items = std.array_list.Managed(T).init(allocator);
    errdefer items.deinit();

    // Parse each row
    var row_count: usize = 0;
    while (scanner.peek()) |line| {
        // Must be indented more than header
        if (line.indent <= base_indent) break;

        // Parse CSV row
        const item = try parseTabularRow(T, line.content, fields, allocator);
        try items.append(item);

        _ = scanner.next();
        row_count += 1;
    }

    // Verify count matches header
    if (row_count != header.length) {
        return error.CountMismatch;
    }

    return items.toOwnedSlice();
}

pub const ArrayHeader = struct {
    key: ?[]const u8,
    length: u64,
    fields: ?[]const []const u8,
    pub fn deinit(self: @This(), allocator: Allocator) void {
        if (self.fields) |fields| for (fields) |field| allocator.free(field);
    }
};

/// Determine if this is a tabular array or primitive array
pub fn parseArray(
    comptime T: type,
    header: ArrayHeader,
    content_after_colon: []const u8,
    scanner: *Scanner,
    base_indent: usize,
    allocator: Allocator,
) ![]T {
    // If header has fields, it's tabular
    if (header.fields != null) {
        return try parseTabularArray(T, header, scanner, base_indent, allocator);
    }

    // Otherwise it's a primitive array on the same line
    return try parsePrimitiveArray(T, header, content_after_colon, allocator);
}

pub fn parsePrimitiveArray(
    comptime T: type,
    header: ArrayHeader,
    content_after_colon: []const u8,
    allocator: Allocator,
) ![]T {
    const type_info = @typeInfo(T);

    // Must be a primitive type
    const is_primitive = switch (type_info) {
        .int, .float, .bool => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };

    if (!is_primitive) return error.TypeMismatch;

    var items = std.array_list.Managed(T).init(allocator);
    errdefer items.deinit();

    // Split by delimiter (comma)
    var value_iter = std.mem.splitScalar(u8, content_after_colon, ',');
    var count: usize = 0;

    while (value_iter.next()) |val| {
        const trimmed = std.mem.trim(u8, val, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const parsed = try parsePrimitiveValue(T, trimmed, allocator);
        try items.append(parsed);
        count += 1;
    }

    // Verify count matches header
    if (count != header.length) {
        return error.CountMismatch;
    }

    return items.toOwnedSlice();
}

pub fn parseArrayHeader(content: []const u8, allocator: Allocator) !ArrayHeader {
    const open_bracket = std.mem.indexOfScalar(u8, content, '[') orelse return error.SyntaxError;
    const close_bracket = std.mem.indexOfScalar(u8, content, ']') orelse return error.SyntaxError;
    const key = std.mem.trim(u8, content[0..open_bracket], &std.ascii.whitespace);
    const length_str = content[open_bracket + 1 .. close_bracket];
    const length = std.fmt.parseInt(usize, length_str, 10) catch return error.InvalidArrayLength;

    // Check for field specification
    var fields: ?[][]const u8 = null;
    const after_bracket = content[close_bracket + 1 ..];

    if (std.mem.indexOfScalar(u8, after_bracket, '{')) |open_brace_idx| {
        const close_brace = std.mem.indexOfScalar(u8, after_bracket, '}') orelse return error.SyntaxError;
        const fields_str = after_bracket[open_brace_idx + 1 .. close_brace];

        var field_list = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (field_list.items) |field| allocator.free(field);
            field_list.deinit();
        }

        var field_iter = std.mem.splitScalar(u8, fields_str, ',');
        while (field_iter.next()) |field| {
            const trimmed = std.mem.trim(u8, field, &std.ascii.whitespace);
            try field_list.append(try allocator.dupe(u8, trimmed));
        }

        fields = try field_list.toOwnedSlice();
    }

    return ArrayHeader{
        .key = key,
        .length = length,
        .fields = fields,
    };
}
pub fn parseArrayField(
    comptime T: type,
    header: ArrayHeader,
    content_after_colon: []const u8,
    scanner: *Scanner,
    base_indent: usize,
    ctx: *Context,
) !T {
    const type_info = @typeInfo(T);

    // Must be a slice
    if (type_info != .pointer) return error.TypeMismatch;
    const ptr_info = type_info.pointer;
    if (ptr_info.size != .slice) return error.TypeMismatch;

    const ChildT = ptr_info.child;

    return try parseArray(
        ChildT,
        header,
        content_after_colon,
        scanner,
        base_indent,
        ctx.allocator,
    );
}

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
