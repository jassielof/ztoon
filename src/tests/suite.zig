const std = @import("std");
const testing = std.testing;

const ztoon = @import("ztoon");

const encoder = @import("encoder.zig");
const decoder = @import("decoder.zig");

test {
    std.testing.refAllDecls(@This());
}

test "JSON API reference for parsing" {
    const TestStruct = struct {
        name: []const u8,
        age: u64,

        // One would have to implement a generic formatter for TOON similar to `std.json.fmt` to use it with the `{f}` format specifier.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("TestStruct{{ .name = \"{s}\", .age = {d} }}", .{ self.name, self.age });
        }
    };
    const json_input =
        \\{
        \\    "name": "Jassiel",
        \\    "age": 23
        \\}
        \\
    ;

    const parsed = try std.json.parseFromSlice(TestStruct, testing.allocator, json_input, .{});
    defer parsed.deinit();

    std.debug.print("Parsed JSON:\n{f}\n", .{parsed.value});
}

test "JSON API reference for stringifying" {
    const TestStruct = struct {
        name: []const u8,
        age: u64,
    };

    const test_struct = TestStruct{ .name = "Jassiel", .age = 23 };

    var json_buffer: [256]u8 = undefined;
    var body_writer = std.Io.Writer.fixed(json_buffer[0..]);

    std.json.Stringify.value(test_struct, .{}, &body_writer) catch |err| {
        std.debug.print("Stringifying JSON failed with:\n{s}\n", .{@errorName(err)});
    };

    const body = std.Io.Writer.buffered(&body_writer);

    std.debug.print("Stringified JSON:\n{s}\n", .{body});
}
