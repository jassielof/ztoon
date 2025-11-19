const std = @import("std");

pub fn parseInt(comptime T: type, content: []const u8) !T {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    return std.fmt.parseInt(T, trimmed, 10) catch error.InvalidNumericLiteral;
}

pub fn parseFloat(comptime T: type, content: []const u8) !T {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    return std.fmt.parseFloat(T, trimmed) catch error.InvalidNumericLiteral;
}
