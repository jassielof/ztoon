//! Decoder tests using spec fixtures
//!
//! This module dynamically loads test fixtures from spec/tests/fixtures/decode/
//! and runs them against the decoder implementation.

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

/// Helper to compare JSON values with TOON values
fn compareValues(allocator: std.mem.Allocator, expected: std.json.Value, actual: ztoon.Value) !bool {
    switch (expected) {
        .null => return actual == .null,
        .bool => |b| return actual == .bool and actual.bool == b,
        .integer => |i| return actual == .number and actual.number == @as(f64, @floatFromInt(i)),
        .float => |f| {
            if (actual != .number) return false;
            // Handle floating point comparison with small epsilon
            const diff = @abs(actual.number - f);
            return diff < 0.0000001;
        },
        .number_string => |s| {
            const num = try std.fmt.parseFloat(f64, s);
            if (actual != .number) return false;
            const diff = @abs(actual.number - num);
            return diff < 0.0000001;
        },
        .string => |s| {
            if (actual != .string) return false;
            return std.mem.eql(u8, actual.string, s);
        },
        .array => |arr| {
            if (actual != .array) return false;
            if (actual.array.len != arr.items.len) return false;
            for (arr.items, actual.array) |exp_item, act_item| {
                if (!try compareValues(allocator, exp_item, act_item)) return false;
            }
            return true;
        },
        .object => |obj| {
            if (actual != .object) return false;
            if (actual.object.count() != obj.count()) return false;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const act_value = actual.object.get(entry.key_ptr.*) orelse return false;
                if (!try compareValues(allocator, entry.value_ptr.*, act_value)) return false;
            }
            return true;
        },
    }
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
        // All decode test inputs should be strings (TOON format)
        const input_str = if (test_case.input == .string) test_case.input.string else {
            std.debug.print("  ⚠ {s}: Input is not a string, skipping\n", .{test_case.name});
            continue;
        };

        // Build decode options
        const options = ztoon.DecodeOptions{
            .indent = if (test_case.options) |opts| opts.indent orelse 2 else 2,
            .strict = if (test_case.options) |opts| opts.strict orelse false else false,
        };

        // Run the test
        if (test_case.shouldError orelse false) {
            // Expect an error
            var success_value = ztoon.decode(allocator, input_str, options) catch {
                std.debug.print("  ✓ {s}\n", .{test_case.name});
                passed += 1;
                continue;
            };
            success_value.deinit(allocator);
            std.debug.print("  ✗ {s}: Expected error but got success\n", .{test_case.name});
            failed += 1;
        } else {
            // Expect success
            var decoded = ztoon.decode(allocator, input_str, options) catch |err| {
                std.debug.print("  ✗ {s}: Decode error: {s}\n", .{ test_case.name, @errorName(err) });
                failed += 1;
                continue;
            };
            defer decoded.deinit(allocator);

            const matches = try compareValues(allocator, test_case.expected, decoded);
            if (matches) {
                std.debug.print("  ✓ {s}\n", .{test_case.name});
                passed += 1;
            } else {
                std.debug.print("  ✗ {s}: Value mismatch\n", .{test_case.name});
                // Debug output for string mismatches
                if (test_case.expected == .string and decoded == .string) {
                    std.debug.print("    Expected string ({d} bytes): '{s}'\n", .{ test_case.expected.string.len, test_case.expected.string });
                    std.debug.print("    Got string      ({d} bytes): '{s}'\n", .{ decoded.string.len, decoded.string });
                }
                failed += 1;
            }
        }
    }

    std.debug.print("  Results: {d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) return error.TestFailure;
}

test "decode fixtures" {
    const allocator = std.testing.allocator;

    const fixture_files = [_][]const u8{
        "spec/tests/fixtures/decode/primitives.json",
        "spec/tests/fixtures/decode/numbers.json",
        "spec/tests/fixtures/decode/objects.json",
        "spec/tests/fixtures/decode/arrays-primitive.json",
        "spec/tests/fixtures/decode/arrays-tabular.json",
        "spec/tests/fixtures/decode/arrays-nested.json",
        // "spec/tests/fixtures/decode/path-expansion.json", // TODO: Implement path expansion
        "spec/tests/fixtures/decode/delimiters.json",
        "spec/tests/fixtures/decode/whitespace.json",
        "spec/tests/fixtures/decode/root-form.json",
        // "spec/tests/fixtures/decode/validation-errors.json", // TODO: Implement strict mode
        // "spec/tests/fixtures/decode/indentation-errors.json", // TODO: Implement strict mode
        // "spec/tests/fixtures/decode/blank-lines.json", // TODO: Implement blank line handling
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
