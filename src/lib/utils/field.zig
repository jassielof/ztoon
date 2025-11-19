const std = @import("std");
const Allocator = std.mem.Allocator;
const case = @import("case.zig");
const snakeToCamel = case.snakeToCamel;

/// Checks if a TOON key matches a Zig field name (handles case conversion)
pub fn fieldMatches(toon_key: []const u8, field_name: []const u8, allocator: Allocator) !bool {
    // Direct match
    if (std.mem.eql(u8, toon_key, field_name)) return true;

    // Try converting field_name to camelCase and compare
    const camel = try snakeToCamel(allocator, field_name);
    defer allocator.free(camel);

    return std.mem.eql(u8, toon_key, camel);
}
