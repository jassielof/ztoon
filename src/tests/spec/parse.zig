const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");
const toonz = @import("toonz");
const Fixture = @import("Fixture.zig");

test "Parse specification fixtures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fixture_files = try utils.loadJsonFixtures(allocator, "spec/tests/fixtures/decode");

    var fxt_it = fixture_files.iterator();
    while (fxt_it.next()) |entry| {
        const fixture = try std.json.parseFromValue(Fixture, allocator, entry.value_ptr.*, .{});

        std.debug.print("Description: {s}\n", .{fixture.value.description});

        for (fixture.value.tests, 0..) |test_case, i| {
            std.debug.print("- Test {}: {s}\n", .{ i + 1, test_case.name });

            std.debug.print("Input:\n{s}\n", .{test_case.input.string});

            // FIXME: There must be compatibility with the JSON data model (for reference Zig's std.json.Value).
            // const parsed_toon = try toonz.Parse.fromSlice(std.json.Value, allocator, test_case.input.string, .{});
            // defer parsed_toon.deinit();
        }
    }
}
