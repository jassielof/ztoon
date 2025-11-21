const std = @import("std");
const types = @import("../../types.zig");
const Allocator = std.mem.Allocator;
const number = @import("number.zig");
const parseStruct = @import("object.zig").parseStruct;
const boolean = @import("boolean.zig");
const isNull = @import("null.zig").isNull;
const string = @import("string.zig");
const Scanner = @import("../../Scanner.zig").Scanner;
const Context = @import("../Context.zig");

pub fn parsePrimitiveValue(comptime T: type, val: []const u8, allocator: Allocator) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => try number.parseInt(T, val),
        .float => try number.parseFloat(T, val),
        .bool => try boolean.parseBool(val),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try string.parseString(val, allocator);
            }
            return error.TypeMismatch;
        },
        else => error.TypeMismatch,
    };
}

pub fn parseNestedValue(
    comptime T: type,
    scanner: *Scanner,
    parent_indent: usize,
    ctx: *Context,
) !T {
    const next_line = scanner.peek() orelse return error.UnexpectedEof;

    // Nested content must be indented more
    if (next_line.indent <= parent_indent) return error.InvalidIndentation;

    return parseValue(T, scanner, next_line.indent, ctx);
}

pub fn parseInlineValue(
    comptime T: type,
    content: []const u8,
    ctx: *Context,
) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => try number.parseInt(T, content),
        .float => try number.parseFloat(T, content),
        .bool => try boolean.parseBool(content),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try string.parseString(content, ctx.allocator);
            }
            return error.TypeMismatch;
        },
        .optional => |opt| blk: {
            if (isNull(content)) {
                break :blk null;
            }
            break :blk try parseInlineValue(opt.child, content, ctx);
        },
        else => error.TypeMismatch,
    };
}

pub fn parseValue(comptime T: type, scanner: *Scanner, base_indent: usize, ctx: *Context) !T {
    if (ctx.depth >= ctx.options.max_depth) return error.SyntaxError;
    ctx.depth += 1;
    defer ctx.depth -= 1;
    const type_info = @typeInfo(T);

    if (T == types.JsonValue or T == std.json.Value) {
        // Read the next line as the JSON string
        const line = scanner.peek() orelse return error.UnexpectedEof;
        _ = scanner.next();
        // Parse using std.json
        return try std.json.parseFromSlice(T, ctx.allocator, line.content, .{});
    }
    return switch (type_info) {
        .@"struct" => try parseStruct(T, scanner, base_indent, ctx),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    // String - read inline
                    const line = scanner.peek() orelse return error.UnexpectedEof;
                    _ = scanner.next();
                    break :blk try string.parseString(line.content, ctx.allocator);
                }
                // Array/slice - should be handled by parseStruct for struct fields
                return error.TypeMismatch;
            }
            return error.TypeMismatch;
        },
        .int, .comptime_int => blk: {
            const line = scanner.peek() orelse return error.UnexpectedEof;
            _ = scanner.next();
            break :blk try number.parseInt(T, line.content);
        },

        .float, .comptime_float => blk: {
            const line = scanner.peek() orelse return error.UnexpectedEof;
            _ = scanner.next();
            break :blk try number.parseFloat(T, line.content);
        },

        .bool => blk: {
            const line = scanner.peek() orelse return error.UnexpectedEof;
            _ = scanner.next();
            break :blk try boolean.parseBool(line.content);
        },

        .optional => |opt| blk: {
            const line = scanner.peek() orelse return null;
            if (isNull(line.content)) {
                _ = scanner.next();
                break :blk null;
            }
            break :blk try parseValue(opt.child, scanner, base_indent, ctx);
        },
        else => @compileError("Cannot parse type: " ++ @typeName(T)),
    };
}

pub fn parseFieldValue(comptime T: type, val: []const u8, allocator: Allocator) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => try number.parseInt(T, val),
        .float => try number.parseFloat(T, val),
        .bool => try boolean.parseBool(val),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try string.parseString(val, allocator);
            }
            return error.TypeMismatch;
        },
        .optional => |opt| blk: {
            if (isNull(val)) {
                break :blk null;
            }
            break :blk try parseFieldValue(opt.child, val, allocator);
        },
        else => error.TypeMismatch,
    };
}
