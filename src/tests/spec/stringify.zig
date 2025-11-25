const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");
const Fixture = @import("Fixture.zig");

test "Stringify specification fixtures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fixtures = try utils.loadJsonFixtures(allocator, "spec/tests/fixtures/encode/");

    var fxt_it = fixtures.iterator();
    while (fxt_it.next()) |entry| {
        const fixture = try std.json.parseFromValue(Fixture, allocator, entry.value_ptr.*, .{});

        std.debug.print("Description: {s}\n", .{fixture.value.description});

        for (fixture.value.tests, 0..) |test_case, i| {
            std.debug.print("- Test {}: {s}\n", .{ i + 1, test_case.name });
            std.debug.print("Input:\n{f}\n", .{std.json.fmt(test_case.input, .{})});
        }
    }
}
