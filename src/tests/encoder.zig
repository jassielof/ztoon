//! Encoder tests using spec fixtures
//!
//! This module dynamically loads test fixtures from spec/tests/fixtures/encode/
//! and runs them against the encoder implementation.

const std = @import("std");
const ztoon = @import("ztoon");

// Test fixtures structure matching the spec JSON schema
const TestCase = struct {
    name: []const u8,
    input: std.json.Value,
    expected: std.json.Value,
    shouldError: ?bool = null,
    options: ?Options = null,
    specSection: ?[]const u8 = null,
    note: ?[]const u8 = null,
    minSpecVersion: ?[]const u8 = null,

    const Options = struct {
        delimiter: ?[]const u8 = null,
        indent: ?usize = null,
        strict: ?bool = null,
        keyFolding: ?[]const u8 = null,
        flattenDepth: ?usize = null,
        expandPaths: ?[]const u8 = null,
    };
};

const Fixtures = struct {
    version: []const u8,
    category: []const u8,
    description: []const u8,
    tests: []TestCase,
};

/// Convert JSON value to TOON Value
fn jsonToToonValue(allocator: std.mem.Allocator, json_val: std.json.Value) !ztoon.Value {
    return switch (json_val) {
        .null => ztoon.Value{ .null = {} },
        .bool => |b| ztoon.Value{ .bool = b },
        .integer => |i| ztoon.Value{ .number = @floatFromInt(i) },
        .float => |f| ztoon.Value{ .number = f },
        .number_string => |s| blk: {
            const num = try std.fmt.parseFloat(f64, s);
            break :blk ztoon.Value{ .number = num };
        },
        .string => |s| ztoon.Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var items = try allocator.alloc(ztoon.Value, arr.items.len);
            errdefer allocator.free(items);

            for (arr.items, 0..) |item, i| {
                items[i] = try jsonToToonValue(allocator, item);
            }

            break :blk ztoon.Value{ .array = items };
        },
        .object => |obj| blk: {
            var map = std.StringArrayHashMap(ztoon.Value).init(allocator);
            errdefer map.deinit();

            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try jsonToToonValue(allocator, entry.value_ptr.*);
                try map.put(key, val);
            }

            break :blk ztoon.Value{ .object = map };
        },
    };
}

/// Parse delimiter from options
fn parseDelimiter(delim_str: []const u8) ztoon.Delimiter {
    if (std.mem.eql(u8, delim_str, ",")) return .comma;
    if (std.mem.eql(u8, delim_str, "\t")) return .tab;
    if (std.mem.eql(u8, delim_str, "|")) return .pipe;
    return .comma; // default
}

/// Load and run a single fixture file
fn runFixtureFile(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const file_content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(file_content);

    const parsed = try std.json.parseFromSlice(Fixtures, allocator, file_content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const fixtures = parsed.value;

    std.debug.print("\n=== {s} ({s}) ===\n", .{ fixtures.description, file_path });

    var passed: usize = 0;
    var failed: usize = 0;

    for (fixtures.tests) |test_case| {
        // Convert JSON input to TOON Value
        var value = try jsonToToonValue(allocator, test_case.input);
        defer value.deinit(allocator);

        // Build encode options
        const options = ztoon.EncodeOptions{
            .indent = if (test_case.options) |opts| opts.indent orelse 2 else 2,
            .delimiter = if (test_case.options) |opts| blk: {
                if (opts.delimiter) |d| {
                    break :blk parseDelimiter(d);
                }
                break :blk .comma;
            } else .comma,
        };

        // Expected output should be a string
        const expected_str = if (test_case.expected == .string) test_case.expected.string else {
            std.debug.print("  ⚠ {s}: Expected output is not a string, skipping\n", .{test_case.name});
            continue;
        };

        // Run the test
        if (test_case.shouldError orelse false) {
            // Expect an error
            const success_value = ztoon.encode(allocator, value, options) catch {
                std.debug.print("  ✓ {s}\n", .{test_case.name});
                passed += 1;
                continue;
            };
            allocator.free(success_value);
            std.debug.print("  ✗ {s}: Expected error but got success\n", .{test_case.name});
            failed += 1;
        } else {
            // Expect success
            const encoded = ztoon.encode(allocator, value, options) catch |err| {
                std.debug.print("  ✗ {s}: Encode error: {s}\n", .{ test_case.name, @errorName(err) });
                failed += 1;
                continue;
            };
            defer allocator.free(encoded);

            if (std.mem.eql(u8, encoded, expected_str)) {
                std.debug.print("  ✓ {s}\n", .{test_case.name});
                passed += 1;
            } else {
                std.debug.print("  ✗ {s}: Output mismatch\n", .{test_case.name});
                std.debug.print("    Expected ({d} bytes): {s}\n", .{ expected_str.len, expected_str });
                std.debug.print("    Got      ({d} bytes): {s}\n", .{ encoded.len, encoded });
                // Debug: show hex for first difference
                const min_len = @min(expected_str.len, encoded.len);
                for (0..min_len) |i| {
                    if (expected_str[i] != encoded[i]) {
                        std.debug.print("    First diff at byte {d}: expected 0x{x} got 0x{x}\n", .{ i, expected_str[i], encoded[i] });
                        break;
                    }
                }
                failed += 1;
            }
        }
    }

    std.debug.print("  Results: {d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) return error.TestFailure;
}

test "encode fixtures" {
    const allocator = std.testing.allocator;

    const fixture_files = [_][]const u8{
        "spec/tests/fixtures/encode/primitives.json",
        "spec/tests/fixtures/encode/objects.json",
        "spec/tests/fixtures/encode/arrays-primitive.json",
        "spec/tests/fixtures/encode/arrays-tabular.json",
        "spec/tests/fixtures/encode/arrays-nested.json",
        "spec/tests/fixtures/encode/arrays-objects.json",
        // "spec/tests/fixtures/encode/key-folding.json", // TODO: Implement key folding
        "spec/tests/fixtures/encode/delimiters.json",
        "spec/tests/fixtures/encode/whitespace.json",
    };

    for (fixture_files) |file_path| {
        runFixtureFile(allocator, file_path) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Skipping missing fixture: {s}\n", .{file_path});
                continue;
            }
            return err;
        };
    }
}
