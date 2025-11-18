const std = @import("std");

/// Errors that can occur during scanning/parsing
pub const ScanError = error{
    /// Tabs are not allowed in indentation in strict mode
    TabsNotAllowedInStrictMode,
    /// Indentation must be exact multiple of indent_size
    InvalidIndentation,
    /// Tabs found in indentation
    TabsInIndentation,
} || std.mem.Allocator.Error;

/// Errors that can occur during parsing
pub const ParseError = error{
    /// Invalid escape sequence in string
    InvalidEscapeSequence,
    /// Unterminated quoted string
    UnterminatedString,
    /// Invalid array length specification
    InvalidArrayLength,
    /// Invalid numeric literal
    InvalidNumericLiteral,
    /// Invalid character in input
    InvalidCharacter,
    /// Syntax error in parsing
    SyntaxError,
} || std.mem.Allocator.Error;

/// Errors that can occur during decoding
pub const DecodeError = error{
    /// No content to decode
    NoContentToDecode,
    /// Expected count doesn't match actual (strict mode)
    CountMismatch,
    /// More items found than expected
    TooManyItems,
    /// Blank lines not allowed in certain contexts (strict mode)
    BlankLinesNotAllowed,
    /// Type mismatch during path expansion
    PathExpansionConflict,
} || ParseError || ScanError;
