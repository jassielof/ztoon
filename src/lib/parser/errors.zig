const std = @import("std");
const Allocator = std.mem.Allocator;

const FromValueError = std.fmt.ParseIntError || std.fmt.ParseFloatError || Allocator.Error || error{
    UnexpectedToken,
    InvalidNumber,
    Overflow,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
};
