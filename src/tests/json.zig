const std = @import("std");
const testing = std.testing;
const toonz = @import("toonz");

const @"sample.toon" = @embedFile("data/sample.toon");
const @"sample.json" = @embedFile("data/sample.json");

test "Parsing with variable schema using Zig's std.json.Value for JSON data model compatibility" {
    // Parse TOON file using std.json.Value
    const parsed_toon = try toonz.Parse.fromSlice(std.json.Value, testing.allocator, @"sample.toon", .{});
    defer parsed_toon.deinit();

    const toon_value = parsed_toon.value;

    // Parse JSON file for comparison
    const parsed_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, @"sample.json", .{});
    defer parsed_json.deinit();

    const json_value = parsed_json.value;

    // Both should be objects
    try testing.expect(toon_value == .object);
    try testing.expect(json_value == .object);

    // Debug: print all keys in the object
    std.debug.print("\n\nKeys in TOON object:\n", .{});
    var it = toon_value.object.iterator();
    while (it.next()) |entry| {
        std.debug.print("  - {s}\n", .{entry.key_ptr.*});
    }

    // Verify we can access the same fields
    const toon_context = toon_value.object.get("context");
    const json_context = json_value.object.get("context");

    try testing.expect(toon_context != null);
    try testing.expect(json_context != null);

    // Print the parsed values for visual verification
    std.debug.print("\n\nParsed TOON as std.json.Value:\n", .{});
    std.debug.print("  context exists: {}\n", .{toon_context != null});
    std.debug.print("  friends exists: {}\n", .{toon_value.object.get("friends") != null});
    std.debug.print("  hikes exists: {}\n", .{toon_value.object.get("hikes") != null});

    // Verify nested object access
    if (toon_context) |ctx| {
        try testing.expect(ctx == .object);
        const task = ctx.object.get("task");
        try testing.expect(task != null);
        try testing.expect(task.? == .string);
        std.debug.print("  task: {s}\n", .{task.?.string});
    }
}

test "JSON compatibility for stringifying" {
    // TODO: Implement TOON stringification
}
