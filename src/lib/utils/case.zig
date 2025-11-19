const std = @import("std");
const Allocator = std.mem.Allocator;
/// Converts snake_case to camelCase
pub fn snakeToCamel(allocator: Allocator, snake: []const u8) ![]const u8 {
    if (snake.len == 0) return try allocator.dupe(u8, snake);

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var capitalize_next = false;
    for (snake) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else if (capitalize_next) {
            try result.append(std.ascii.toUpper(c));
            capitalize_next = false;
        } else {
            try result.append(c);
        }
    }

    return result.toOwnedSlice();
}

/// Converts camelCase to snake_case
pub fn camelToSnake(allocator: Allocator, camel: []const u8) ![]const u8 {
    if (camel.len == 0) return try allocator.dupe(u8, camel);

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    for (camel, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) {
                try result.append('_');
            }
            try result.append(std.ascii.toLower(c));
        } else {
            try result.append(c);
        }
    }

    return result.toOwnedSlice();
}
