const std = @import("std");
const ztoon = @import("ztoon");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test case: { "items": ["-"] }
    var obj = std.StringArrayHashMap(ztoon.Value).init(allocator);
    defer obj.deinit();

    var arr = try allocator.alloc(ztoon.Value, 1);
    arr[0] = ztoon.Value{ .string = try allocator.dupe(u8, "-") };

    const key = try allocator.dupe(u8, "items");
    try obj.put(key, ztoon.Value{ .array = arr });

    const value = ztoon.Value{ .object = obj };

    const encoded = try ztoon.encode(allocator, value, .{});
    defer allocator.free(encoded);

    std.debug.print("Encoded: {s}\n", .{encoded});
}
