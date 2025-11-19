//! Writes TOON formatted data to a stream

const std = @import("std");
const Stringify = @This();
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
