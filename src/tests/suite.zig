const std = @import("std");
const testing = std.testing;

const ztoon = @import("ztoon");

comptime {
    _ = @import("basic.zig");
    _ = @import("parsing.zig");
    _ = @import("stringify.zig");
}

test {
    testing.refAllDecls(@This());
}
