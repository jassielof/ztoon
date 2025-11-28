const std = @import("std");
const testing = std.testing;
const toonz = @import("toonz");
const Fixture = @import("Fixture.zig");

test "Parse specification fixtures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fixture_files = try Fixture.loadFromDir(allocator, "spec/tests/fixtures/decode");

    var fxt_it = fixture_files.iterator();
    while (fxt_it.next()) |entry| {
        const fixture = try std.json.parseFromValue(Fixture, allocator, entry.value_ptr.*, .{});

        std.debug.print("Description: {s}\n", .{fixture.value.description});

        for (fixture.value.tests, 0..) |test_case, i| {
            std.debug.print("- Test {}: {s}\n", .{ i + 1, test_case.name });

            std.debug.print("Input:\n{s}\n", .{test_case.input.string});
            std.debug.print("Should throw error?: {any}\n", .{test_case.shouldError});

            // Build parser options from fixture options
            var parse_options: toonz.Parse.Options = .{};
            if (test_case.options) |opts| {
                if (opts.strict) |strict| {
                    parse_options.strict = strict;
                }
                if (opts.indent) |indent| {
                    parse_options.indent = @intCast(indent);
                }
                if (opts.expandPaths) |expand| {
                    if (std.mem.eql(u8, expand, "safe")) {
                        parse_options.expand_paths = .safe;
                    } else {
                        parse_options.expand_paths = .off;
                    }
                }
            }

            if (test_case.shouldError) {
                // Test expects an error - check that parsing fails
                const result = toonz.Parse.fromSlice(toonz.Value, allocator, test_case.input.string, parse_options);
                if (result) |_| {
                    // Parsing succeeded when it should have failed
                    return error.TestExpectedError;
                } else |_| {
                    // Parsing failed as expected
                }
                continue;
            } else {
                const parsed_toon = try toonz.Parse.fromSlice(toonz.Value, allocator, test_case.input.string, parse_options);
                std.debug.print("{f}\n", .{toonz.format.fmt(parsed_toon.value, .{})});

                // TODO: Compare parsed_toon.value with test_case.expected
            }
        }
    }
}
