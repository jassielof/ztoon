const std = @import("std");
const testing = std.testing;
const toonz = @import("toonz");

const @"sample.toon" = @embedFile("data/sample.toon");
const @"sample.json" = @embedFile("data/sample.json");

const Sample = struct { context: struct {
    task: []const u8,
    location: []const u8,
    season: []const u8,
}, friends: []const []const u8, hikes: []const struct {
    id: u64,
    name: []const u8,
    distanceKm: f64,
    elevationGain: u64,
    companion: []const u8,
    wasSunny: bool,
} };

test "Basic parsing with fixed schema" {
    const parsed = try toonz.Parse.fromSlice(Sample, testing.allocator, @"sample.toon", .{});
    defer parsed.deinit();

    const actual = parsed.value;

    const expected = try std.json.parseFromSlice(Sample, testing.allocator, @"sample.json", .{});
    defer expected.deinit();

    try testing.expectEqualDeep(expected.value, actual);
}

test "Basic parsing with variable schema" {
    const parsed = try toonz.Parse.fromSlice(toonz.Value, testing.allocator, @"sample.toon", .{});
    defer parsed.deinit();

    const parsed_val = parsed.value;

    std.debug.print("{f}\n", .{toonz.format.fmt(parsed_val, .{})});
}

test "Basic stringifying with fixed schema" {}

test "Basic stringifying with variable schema" {}
