const std = @import("std");
const testing = std.testing;
const ztoon = @import("ztoon");

const toon_sample =
    \\context:
    \\  task: Our favorite hikes together
    \\  location: Boulder
    \\  season: spring_2025
    \\
    \\friends[3]: ana,luis,sam
    \\
    \\hikes[3]{id,name,distanceKm,elevationGain,companion,wasSunny}:
    \\  1,Blue Lake Trail,7.5,320,ana,true
    \\  2,Ridge Overlook,9.2,540,luis,false
    \\  3,Wildflower Loop,5.1,180,sam,true
    \\
;

const json_sample =
    \\{
    \\  "context": {
    \\    "task": "Our favorite hikes together",
    \\    "location": "Boulder",
    \\    "season": "spring_2025"
    \\  },
    \\  "friends": ["ana", "luis", "sam"],
    \\  "hikes": [
    \\    {
    \\      "id": 1,
    \\      "name": "Blue Lake Trail",
    \\      "distanceKm": 7.5,
    \\      "elevationGain": 320,
    \\      "companion": "ana",
    \\      "wasSunny": true
    \\    },
    \\    {
    \\      "id": 2,
    \\      "name": "Ridge Overlook",
    \\      "distanceKm": 9.2,
    \\      "elevationGain": 540,
    \\      "companion": "luis",
    \\      "wasSunny": false
    \\    },
    \\    {
    \\      "id": 3,
    \\      "name": "Wildflower Loop",
    \\      "distanceKm": 5.1,
    \\      "elevationGain": 180,
    \\      "companion": "sam",
    \\      "wasSunny": true
    \\    }
    \\  ]
    \\}
    \\
;

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
    const parsed = try ztoon.Parse.fromSlice(Sample, testing.allocator, toon_sample, .{});
    defer parsed.deinit();

    const actual_str = std.json.fmt(parsed.value, .{});

    const expected = try std.json.parseFromSlice(Sample, testing.allocator, json_sample, .{});
    defer expected.deinit();

    const expected_str = std.json.fmt(expected.value, .{});

    std.debug.print("Parsed TOON:\n{f}\n", .{actual_str});

    std.debug.print("Expected JSON:\n{f}\n", .{expected_str});
}

test "Basic stringify" {
    // std.debug.print("Stringified TOON:\n{f}\n", .{});
}
