const std = @import("std");
const testing = std.testing;
const toonz = @import("toonz");

const toon_sample =
    \\name: Jassiel
    \\age: 23
    \\
;

test "Formatting TOON value with fmt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse TOON
    const parsed = try toonz.Parse.fromSlice(toonz.Value, allocator, toon_sample, .{});
    defer parsed.deinit();

    // Format using the fmt function
    std.debug.print("Formatted TOON:\n{f}\n", .{toonz.format.fmt(parsed.value, .{})});
}

test "Formatting TOON with arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a TOON value with arrays
    var root_obj = toonz.Value.Object.init(allocator);
    defer {
        var it = root_obj.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        root_obj.deinit();
    }

    // Add primitive array
    var tags_array = toonz.Value.Array.init(allocator);
    try tags_array.append(.{ .string = "developer" });
    try tags_array.append(.{ .string = "zig" });
    try tags_array.append(.{ .string = "toon" });
    const tags_owned = try tags_array.toOwnedSlice();
    try root_obj.put(try allocator.dupe(u8, "tags"), .{ .array = .{ .items = tags_owned, .capacity = tags_owned.len } });

    // Add tabular array
    var users_array = toonz.Value.Array.init(allocator);

    var user1 = toonz.Value.Object.init(allocator);
    try user1.put(try allocator.dupe(u8, "id"), .{ .integer = 1 });
    try user1.put(try allocator.dupe(u8, "name"), .{ .string = "Alice" });
    try users_array.append(.{ .object = user1 });

    var user2 = toonz.Value.Object.init(allocator);
    try user2.put(try allocator.dupe(u8, "id"), .{ .integer = 2 });
    try user2.put(try allocator.dupe(u8, "name"), .{ .string = "Bob" });
    try users_array.append(.{ .object = user2 });

    const users_owned = try users_array.toOwnedSlice();
    try root_obj.put(try allocator.dupe(u8, "users"), .{ .array = .{ .items = users_owned, .capacity = users_owned.len } });

    const root_value = toonz.Value{ .object = root_obj };

    // Format using the fmt function
    std.debug.print("Formatted TOON with arrays:\n{f}\n", .{toonz.format.fmt(root_value, .{})});
}
