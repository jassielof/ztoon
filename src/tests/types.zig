const std = @import("std");

pub const TestOptions = struct {
    delimiter: ?[]const u8 = null,
    indent: ?u64 = null,
    strict: ?bool = null,
    keyFolding: ?[]const u8 = null,
    flattenDepth: ?u64 = null,
    expandPaths: ?[]const u8 = null,
};

pub const TestCase = struct {
    name: []const u8,
    input: std.json.Value,
    expected: std.json.Value,
    shouldError: bool = false,
    options: ?TestOptions = null,
    specSection: ?[]const u8 = null,
    note: ?[]const u8 = null,
    minSpecVersion: ?[]const u8 = null,
};

pub const Fixtures = struct {
    version: []const u8,
    category: []const u8,
    description: []const u8,
    tests: []TestCase,
};
