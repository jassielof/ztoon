//! file docs
const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = @import("Options.zig");

/// const context docs
const Context = @This();

allocator: Allocator,
options: Options,
depth: usize,
