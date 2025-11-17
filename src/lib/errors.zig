const std = @import("std");

pub const CommandError = error{
    UnknownCommand,
    InvalidArguments,
    FileNotFound,
};

pub const ScanError = error{
    TabsNotAllowedInStrictMode,
    InvalidIndentation,
    OutOfMemory,
    TabsInIndentation,
} || std.mem.Allocator.Error;
