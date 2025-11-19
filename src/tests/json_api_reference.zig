const std = @import("std");
const testing = std.testing;

const json_sample =
    \\{
    \\  "name": "Jassiel",
    \\  "age": 23
    \\}
    \\
;

const Sample = struct {
    name: []const u8,
    age: u64,

    // One would have to implement a generic formatter for TOON similar to `std.json.fmt` to use it with the `{f}` format specifier.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("TestStruct{{ .name = \"{s}\", .age = {d} }}", .{ self.name, self.age });
    }
};

const struct_sample = Sample{ .name = "Jassiel", .age = 23 };

test "JSON API reference for parsing" {
    const parsed = try std.json.parseFromSlice(Sample, testing.allocator, json_sample, .{});
    defer parsed.deinit();

    std.debug.print("Parsed JSON:\n{f}\n", .{parsed.value});

    std.debug.print("Formatted parsed JSON:\n{f}\n", .{std.json.fmt(parsed.value, .{})});
}

test "JSON API reference for stringifying" {
    var json_buffer: [256]u8 = undefined;
    var body_writer = std.Io.Writer.fixed(json_buffer[0..]);

    std.json.Stringify.value(struct_sample, .{}, &body_writer) catch |err| {
        std.debug.print("Stringifying JSON failed with:\n{s}\n", .{@errorName(err)});
    };

    const body = std.Io.Writer.buffered(&body_writer);

    std.debug.print("Stringified JSON:\n{s}\n", .{body});
}
