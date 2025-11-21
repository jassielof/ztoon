const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");
const types = @import("types.zig");

test "Stringify specification fixtures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fixtures = try utils.loadJsonFixtures(allocator, "spec/tests/fixtures/encode/");

    var fxt_it = fixtures.iterator();
    while (fxt_it.next()) |entry| {
        const fixture = try std.json.parseFromValue(types.Fixtures, allocator, entry.value_ptr.*, .{});
        defer fixture.deinit();

        std.debug.print("Description: {s}\n", .{fixture.value.description});

        for (fixture.value.tests, 0..) |test_case, i| {
            std.debug.print("\tTest {}: {s}\n", .{ i + 1, test_case.name });

            std.debug.print("\tInput:\n{any}\n", .{test_case.input.object});
        }
    }
}
