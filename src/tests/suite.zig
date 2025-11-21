const std = @import("std");
const testing = std.testing;

const toonz = @import("toonz");

comptime {
    _ = @import("basic.zig");
    _ = @import("parse.zig");
    // _ = @import("stringify.zig");
}

test {
    testing.refAllDecls(@This());
}
