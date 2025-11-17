const std = @import("std");
const ztoon = @import("ztoon");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test case
    var items = try allocator.alloc(ztoon.Value, 2);

    var obj1 = std.StringArrayHashMap(ztoon.Value).init(allocator);
    try obj1.put(try allocator.dupe(u8, "sku"), ztoon.Value{ .string = try allocator.dupe(u8, "A1") });
    try obj1.put(try allocator.dupe(u8, "qty"), ztoon.Value{ .number = 2 });
    items[0] = ztoon.Value{ .object = obj1 };

    var obj2 = std.StringArrayHashMap(ztoon.Value).init(allocator);
    try obj2.put(try allocator.dupe(u8, "sku"), ztoon.Value{ .string = try allocator.dupe(u8, "B2") });
    try obj2.put(try allocator.dupe(u8, "qty"), ztoon.Value{ .number = 1 });
    items[1] = ztoon.Value{ .object = obj2 };

    var root = std.StringArrayHashMap(ztoon.Value).init(allocator);
    try root.put(try allocator.dupe(u8, "items"), ztoon.Value{ .array = items });

    const value = ztoon.Value{ .object = root };

    const encoded = try ztoon.encode(allocator, value, .{});
    defer allocator.free(encoded);

    std.debug.print("Encoded:\n", .{});
    for (encoded, 0..) |c, i| {
        if (c == '\n') {
            std.debug.print("\\n (byte {})\n", .{i});
        } else if (c == ' ') {
            std.debug.print("␣", .{});
        } else if (c == '\t') {
            std.debug.print("→", .{});
        } else {
            std.debug.print("{c}", .{c});
        }
    }
    std.debug.print("\n", .{});
}
