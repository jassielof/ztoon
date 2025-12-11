//! Format command: Format TOON files (TODO - not yet implemented)

const std = @import("std");
const errors = @import("../errors.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const stderr_file = std.fs.File.stderr();
    try stderr_file.writeAll("Error: Format command is not yet implemented.\n");
    return error.Unimplemented;
}
