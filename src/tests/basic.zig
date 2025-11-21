const std = @import("std");
const testing = std.testing;
const toonz = @import("toonz");

const @"toon.sample" = @embedFile("data/sample.toon");
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

test "Basic parsing" {
    const parsed = try toonz.Parse.fromSlice(Sample, testing.allocator, @"toon.sample", .{});
    defer parsed.deinit();

    const actual = parsed.value;

    const expected = try std.json.parseFromSlice(Sample, testing.allocator, @"sample.json", .{});
    defer expected.deinit();

    try testing.expectEqualDeep(expected.value, actual);
}

test "Basic stringifying" {}
