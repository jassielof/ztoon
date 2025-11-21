const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors that can occur when converting from a parsed value to a specific type.
const FromValueError = std.fmt.ParseIntError || std.fmt.ParseFloatError || Allocator.Error || error{
    /// The syntax of the input is invalid.
    UnexpectedToken,

    /// A number could not be parsed.
    InvalidNumber,

    /// An integer overflow occurred.
    Overflow,

    /// An enum tag did not match any known variants.
    InvalidEnumTag,

    /// A field was specified more than once.
    DuplicateField,

    /// A field name was not recognized.
    UnknownField,

    /// A required field was missing.
    MissingField,

    /// The length of an array did not match the expected length.
    LengthMismatch,
};
