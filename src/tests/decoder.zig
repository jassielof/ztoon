const std = @import("std");
const ztoon = @import("ztoon");
const test_types = @import("types.zig");
const testing = std.testing;

const fixtures_path = "spec/tests/fixtures/decode/";
const fixtures = [_][]const u8{
    "primitives.json",
    "numbers.json",
    "objects.json",
    "arrays-primitive.json",
    "arrays-tabular.json",
    "arrays-nested.json",
    "path-expansion.json",
    "delimiters.json",
    "whitespace.json",
    "root-form.json",
    "validation-errors.json",
    "indentation-errors.json",
    "blank-lines.json",
};

/// Convert test options to decoding options
fn convertTestOptionsToDecodeOptions(test_options: ?test_types.TestOptions) ?ztoon.DecodingOptions {
    if (test_options) |opts| {
        var decode_opts = ztoon.DecodingOptions{};

        if (opts.indent) |indent| {
            decode_opts.indent = indent;
        }
        if (opts.strict) |strict| {
            decode_opts.strict = strict;
        }
        if (opts.expandPaths) |expand_paths| {
            if (std.mem.eql(u8, expand_paths, "safe")) {
                decode_opts.expand_paths = .safe;
            } else {
                decode_opts.expand_paths = .off;
            }
        }

        return decode_opts;
    }
    return null;
}

/// Compare two std.json.Value objects for equality
fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |a_val| {
            if (b != .bool) return false;
            return a_val == b.bool;
        },
        .integer => |a_val| {
            return switch (b) {
                .integer => |b_val| a_val == b_val,
                .float => |b_val| @as(f64, @floatFromInt(a_val)) == b_val,
                else => false,
            };
        },
        .float => |a_val| {
            return switch (b) {
                .float => |b_val| a_val == b_val,
                .integer => |b_val| a_val == @as(f64, @floatFromInt(b_val)),
                else => false,
            };
        },
        .number_string => |a_val| {
            if (b != .number_string) return false;
            return std.mem.eql(u8, a_val, b.number_string);
        },
        .string => |a_val| {
            if (b != .string) return false;
            return std.mem.eql(u8, a_val, b.string);
        },
        .array => |a_arr| {
            if (b != .array) return false;
            const b_arr = b.array;
            if (a_arr.items.len != b_arr.items.len) return false;
            for (a_arr.items, b_arr.items) |a_item, b_item| {
                if (!jsonValuesEqual(a_item, b_item)) return false;
            }
            return true;
        },
        .object => |a_obj| {
            if (b != .object) return false;
            const b_obj = b.object;
            if (a_obj.count() != b_obj.count()) return false;
            var it = a_obj.iterator();
            while (it.next()) |entry| {
                const b_val = b_obj.get(entry.key_ptr.*) orelse return false;
                if (!jsonValuesEqual(entry.value_ptr.*, b_val)) return false;
            }
            return true;
        },
    }
}

/// Convert ztoon.JsonValue to std.json.Value for comparison
fn ztoonValueToStdJsonValue(allocator: std.mem.Allocator, value: ztoon.JsonValue) !std.json.Value {
    return switch (value) {
        .primitive => |prim| switch (prim) {
            .null => .null,
            .boolean => |b| .{ .bool = b },
            .number => |n| .{ .float = n },
            .string => |s| .{ .string = s },
        },
        .array => |arr| blk: {
            var std_arr = std.json.Array.init(allocator);
            errdefer std_arr.deinit();
            for (arr.items) |item| {
                const converted = try ztoonValueToStdJsonValue(allocator, item);
                try std_arr.append(converted);
            }
            break :blk .{ .array = std_arr };
        },
        .object => |obj| blk: {
            var std_obj = std.json.ObjectMap.init(allocator);
            errdefer std_obj.deinit();
            var it = obj.iterator();
            while (it.next()) |entry| {
                const converted = try ztoonValueToStdJsonValue(allocator, entry.value_ptr.*);
                try std_obj.put(entry.key_ptr.*, converted);
            }
            break :blk .{ .object = std_obj };
        },
    };
}

/// Free a ztoon.JsonValue recursively
fn freeZtoonValue(allocator: std.mem.Allocator, value: ztoon.JsonValue) void {
    switch (value) {
        .array => |arr| {
            for (arr.items) |item| {
                freeZtoonValue(allocator, item);
            }
            arr.deinit(allocator);
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                freeZtoonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit();
        },
        .primitive => {},
    }
}

/// Free a std.json.Value recursively
fn freeStdJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .array => |arr| {
            for (arr.items) |item| {
                freeStdJsonValue(allocator, item);
            }
            arr.deinit(allocator);
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                freeStdJsonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit();
        },
        else => {},
    }
}

/// Run tests from a fixture file
fn runFixtureTests(allocator: std.mem.Allocator, fixture_file: test_types.Fixtures) !void {
    for (fixture_file.tests) |test_case| {
        std.debug.print("  Running: {s}\n", .{test_case.name});

        // Get the input as a string
        const input_str = switch (test_case.input) {
            .string => |s| s,
            else => {
                std.debug.print("    SKIP: input is not a string\n", .{});
                continue;
            },
        };

        const decode_options = convertTestOptionsToDecodeOptions(test_case.options);

        if (test_case.shouldError) {
            // Expect this to fail
            const result = ztoon.decode(allocator, input_str, decode_options);
            if (result) |value| {
                // Shouldn't succeed, but clean up if it does
                freeZtoonValue(allocator, value);
                std.debug.print("    FAIL: Expected error but got success\n", .{});
                return error.TestExpectedError;
            } else |_| {
                // Expected to fail
                std.debug.print("    PASS: Got expected error\n", .{});
            }
        } else {
            // Expect this to succeed
            const result = ztoon.decode(allocator, input_str, decode_options) catch |err| {
                std.debug.print("    FAIL: Unexpected error: {any}\n", .{err});
                return err;
            };
            defer freeZtoonValue(allocator, result);

            // Convert ztoon JsonValue to std.json.Value for comparison
            const result_as_std_json = try ztoonValueToStdJsonValue(allocator, result);
            defer freeStdJsonValue(allocator, result_as_std_json);

            if (jsonValuesEqual(test_case.expected, result_as_std_json)) {
                std.debug.print("    PASS\n", .{});
            } else {
                std.debug.print("    FAIL: Values don't match\n", .{});
                std.debug.print("      Expected: {any}\n", .{test_case.expected});
                std.debug.print("      Got: {any}\n", .{result_as_std_json});
                return error.TestValueMismatch;
            }
        }
    }
}

test "decode all fixtures" {
    inline for (fixtures) |fixture| {
        std.debug.print("\nTesting fixture: {s}\n", .{fixture});

        const full_path = try std.fs.path.join(
            testing.allocator,
            &.{ fixtures_path, fixture },
        );
        defer testing.allocator.free(full_path);

        const file_content = try std.fs.cwd().readFileAlloc(
            testing.allocator,
            full_path,
            1024 * 1024,
        );
        defer testing.allocator.free(file_content);

        // Parse the JSON fixture file
        const parsed = try std.json.parseFromSlice(
            test_types.Fixtures,
            testing.allocator,
            file_content,
            .{},
        );
        defer parsed.deinit();

        try runFixtureTests(testing.allocator, parsed.value);
    }
}
