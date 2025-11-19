const std = @import("std");

pub fn parseBool(content: []const u8) !bool {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "true")) return true;
    if (std.mem.eql(u8, trimmed, "false")) return false;

    return error.InvalidBooleanLiteral;
}
