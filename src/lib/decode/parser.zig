const std = @import("std");
const types = @import("../types.zig");
const constants = @import("../constants.zig");
const errors = @import("../errors.zig");
const validation = @import("validation.zig");

const Allocator = std.mem.Allocator;
const ArrayHeaderInfo = types.ArrayHeaderInfo;
const JsonPrimitive = types.JsonPrimitive;
const Delimiter = constants.Delimiter;

// Constants for parsing
const BACKSLASH = constants.backslash;
const DOUBLE_QUOTE = constants.double_quote;
const NEWLINE = constants.newline;
const CARRIAGE_RETURN = constants.carriage_return;
const TAB = constants.tab;
const COLON = constants.colon;
const COMMA = constants.comma;
const PIPE = constants.pipe;
const OPEN_BRACKET = constants.open_bracket;
const CLOSE_BRACKET = constants.close_bracket;
const OPEN_BRACE = constants.open_brace;
const CLOSE_BRACE = constants.close_brace;
const DOT = constants.dot;

// #region String utilities

/// Unescapes a string by processing escape sequences
pub fn unescapeString(allocator: Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == BACKSLASH) {
            if (i + 1 >= value.len) {
                return errors.ParseError.InvalidEscapeSequence;
            }

            const next = value[i + 1];
            switch (next) {
                'n' => {
                    try result.append(allocator, '\n');
                    i += 2;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 2;
                },
                BACKSLASH => {
                    try result.append(allocator, BACKSLASH);
                    i += 2;
                },
                DOUBLE_QUOTE => {
                    try result.append(allocator, DOUBLE_QUOTE);
                    i += 2;
                },
                else => return errors.ParseError.InvalidEscapeSequence,
            }
        } else {
            try result.append(allocator, value[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Finds the index of the closing double quote, accounting for escape sequences
pub fn findClosingQuote(content: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < content.len) {
        if (content[i] == BACKSLASH and i + 1 < content.len) {
            // Skip escaped character
            i += 2;
            continue;
        }
        if (content[i] == DOUBLE_QUOTE) {
            return i;
        }
        i += 1;
    }
    return null;
}

/// Finds the index of a character outside of quoted sections
pub fn findUnquotedChar(content: []const u8, char: u8, start: usize) ?usize {
    var in_quotes = false;
    var i = start;

    while (i < content.len) {
        if (content[i] == BACKSLASH and i + 1 < content.len and in_quotes) {
            // Skip escaped character
            i += 2;
            continue;
        }

        if (content[i] == DOUBLE_QUOTE) {
            in_quotes = !in_quotes;
            i += 1;
            continue;
        }

        if (content[i] == char and !in_quotes) {
            return i;
        }

        i += 1;
    }

    return null;
}

// #endregion

// #region Primitive parsing

/// Parses a primitive token (string, number, boolean, or null)
pub fn parsePrimitiveToken(allocator: Allocator, token: []const u8) !JsonPrimitive {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);

    // Check for quoted string
    if (trimmed.len >= 2 and trimmed[0] == DOUBLE_QUOTE and trimmed[trimmed.len - 1] == DOUBLE_QUOTE) {
        const unquoted = trimmed[1 .. trimmed.len - 1];
        const unescaped = try unescapeString(allocator, unquoted);
        return JsonPrimitive{ .string = unescaped };
    }

    // Check for boolean literals
    if (std.mem.eql(u8, trimmed, constants.true_literal)) {
        return JsonPrimitive{ .boolean = true };
    }
    if (std.mem.eql(u8, trimmed, constants.false_literal)) {
        return JsonPrimitive{ .boolean = false };
    }

    // Check for null
    if (std.mem.eql(u8, trimmed, constants.null_literal)) {
        return JsonPrimitive{ .null = {} };
    }

    // Try to parse as number
    if (validation.isNumericLiteral(trimmed)) {
        const number = try std.fmt.parseFloat(f64, trimmed);
        return JsonPrimitive{ .number = number };
    }

    // Unquoted string
    const unquoted_str = try allocator.dupe(u8, trimmed);
    return JsonPrimitive{ .string = unquoted_str };
}

/// Parses a string literal (removes quotes and unescapes)
pub fn parseStringLiteral(allocator: Allocator, token: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);

    if (trimmed.len >= 2 and trimmed[0] == DOUBLE_QUOTE and trimmed[trimmed.len - 1] == DOUBLE_QUOTE) {
        const unquoted = trimmed[1 .. trimmed.len - 1];
        return try unescapeString(allocator, unquoted);
    }

    return try allocator.dupe(u8, trimmed);
}

// #endregion

// #region Key parsing

pub const ParseKeyResult = struct {
    key: []u8,
    end: usize,
    is_quoted: bool,
};

/// Parses a key token (quoted or unquoted)
pub fn parseKeyToken(allocator: Allocator, content: []const u8, start: usize) !ParseKeyResult {
    const trimmed_start = blk: {
        var i = start;
        while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
        break :blk i;
    };

    if (trimmed_start >= content.len) {
        return errors.ParseError.SyntaxError;
    }

    if (content[trimmed_start] == DOUBLE_QUOTE) {
        return try parseQuotedKey(allocator, content, trimmed_start);
    } else {
        return try parseUnquotedKey(allocator, content, trimmed_start);
    }
}

fn parseUnquotedKey(allocator: Allocator, content: []const u8, start: usize) !ParseKeyResult {
    var parse_pos = start;
    while (parse_pos < content.len and content[parse_pos] != COLON) : (parse_pos += 1) {}

    if (parse_pos >= content.len) {
        return errors.ParseError.SyntaxError;
    }

    const key_str = std.mem.trim(u8, content[start..parse_pos], &std.ascii.whitespace);
    const key = try allocator.dupe(u8, key_str);

    // Find colon, skip any array/brace syntax
    const end_pos = parse_pos + 1;

    return ParseKeyResult{
        .key = key,
        .end = end_pos,
        .is_quoted = false,
    };
}

fn parseQuotedKey(allocator: Allocator, content: []const u8, start: usize) !ParseKeyResult {
    const closing_quote = findClosingQuote(content, start) orelse return errors.ParseError.UnterminatedString;

    const quoted_key = content[start + 1 .. closing_quote];
    const key = try unescapeString(allocator, quoted_key);

    // Find colon after the quoted key
    var pos = closing_quote + 1;
    while (pos < content.len and content[pos] != COLON) : (pos += 1) {}

    if (pos >= content.len) {
        return errors.ParseError.SyntaxError;
    }

    return ParseKeyResult{
        .key = key,
        .end = pos + 1,
        .is_quoted = true,
    };
}

// #endregion

// #region Array header parsing

pub const ParseArrayHeaderResult = struct {
    header: ArrayHeaderInfo,
    inline_values: ?[]const u8,
};

/// Parses an array header line (e.g., "key[5]{field1,field2}: value1,value2")
pub fn parseArrayHeaderLine(
    allocator: Allocator,
    content: []const u8,
    default_delimiter: Delimiter,
) !?ParseArrayHeaderResult {
    const trimmed = std.mem.trimLeft(u8, content, &std.ascii.whitespace);

    // Find the bracket segment
    var bracket_start: ?usize = null;

    // For quoted keys, find bracket after closing quote
    if (std.mem.startsWith(u8, trimmed, &[_]u8{DOUBLE_QUOTE})) {
        const closing_quote_idx = findClosingQuote(trimmed, 0) orelse return null;
        const after_quote = trimmed[closing_quote_idx + 1 ..];

        if (!std.mem.startsWith(u8, after_quote, &[_]u8{OPEN_BRACKET})) {
            return null;
        }

        const leading_ws = content.len - trimmed.len;
        const key_end_idx = leading_ws + closing_quote_idx + 1;
        bracket_start = std.mem.indexOfScalarPos(u8, content, key_end_idx, OPEN_BRACKET);
    } else {
        bracket_start = std.mem.indexOfScalar(u8, content, OPEN_BRACKET);
    }

    if (bracket_start == null) return null;

    const bracket_end = std.mem.indexOfScalarPos(u8, content, bracket_start.?, CLOSE_BRACKET) orelse return null;

    // Find colon after brackets and braces
    var colon_idx = bracket_end + 1;
    var brace_end = colon_idx;

    // Check for fields segment (braces after bracket)
    const brace_start = std.mem.indexOfScalarPos(u8, content, bracket_end, OPEN_BRACE);
    if (brace_start) |bs| {
        const colon_after_bracket = std.mem.indexOfScalarPos(u8, content, bracket_end, COLON) orelse return null;
        if (bs < colon_after_bracket) {
            const found_brace_end = std.mem.indexOfScalarPos(u8, content, bs, CLOSE_BRACE);
            if (found_brace_end) |be| {
                brace_end = be + 1;
            }
        }
    }

    colon_idx = std.mem.indexOfScalarPos(u8, content, @max(bracket_end, brace_end), COLON) orelse return null;

    // Extract key
    var key: ?[]u8 = null;
    if (bracket_start.? > 0) {
        const raw_key = std.mem.trim(u8, content[0..bracket_start.?], &std.ascii.whitespace);
        key = try parseStringLiteral(allocator, raw_key);
    }

    const after_colon = std.mem.trim(u8, content[colon_idx + 1 ..], &std.ascii.whitespace);

    const bracket_content = content[bracket_start.? + 1 .. bracket_end];

    // Parse bracket segment
    const parsed_bracket = try parseBracketSegment(bracket_content, default_delimiter);

    // Check for fields segment
    var fields: ?[][]u8 = null;
    if (brace_start) |bs| {
        if (bs < colon_idx) {
            const found_brace_end = std.mem.indexOfScalarPos(u8, content, bs, CLOSE_BRACE);
            if (found_brace_end) |be| {
                if (be < colon_idx) {
                    const fields_content = content[bs + 1 .. be];
                    const field_strs = try parseDelimitedValues(allocator, fields_content, parsed_bracket.delimiter);

                    var field_list = std.ArrayList([]u8){};
                    for (field_strs) |field| {
                        const trimmed_field = std.mem.trim(u8, field, &std.ascii.whitespace);
                        const parsed_field = try parseStringLiteral(allocator, trimmed_field);
                        try field_list.append(allocator, parsed_field);
                    }
                    fields = try field_list.toOwnedSlice(allocator);
                }
            }
        }
    }

    return ParseArrayHeaderResult{
        .header = ArrayHeaderInfo{
            .key = key,
            .length = parsed_bracket.length,
            .delimiter = parsed_bracket.delimiter,
            .fields = fields,
        },
        .inline_values = if (after_colon.len > 0) after_colon else null,
    };
}

pub const ParseBracketResult = struct {
    length: u64,
    delimiter: Delimiter,
};

/// Parses bracket segment (e.g., "5" or "10|" or "3\t")
pub fn parseBracketSegment(seg: []const u8, default_delimiter: Delimiter) !ParseBracketResult {
    var content = seg;
    var delimiter = default_delimiter;

    // Check for delimiter suffix
    if (content.len > 0 and content[content.len - 1] == TAB) {
        delimiter = constants.Delimiters.tab;
        content = content[0 .. content.len - 1];
    } else if (content.len > 0 and content[content.len - 1] == PIPE) {
        delimiter = constants.Delimiters.pipe;
        content = content[0 .. content.len - 1];
    }

    const length = std.fmt.parseInt(u64, content, 10) catch {
        return errors.ParseError.InvalidArrayLength;
    };

    return ParseBracketResult{
        .length = length,
        .delimiter = delimiter,
    };
}

/// Parses delimited values respecting quotes and escape sequences
pub fn parseDelimitedValues(allocator: Allocator, input: []const u8, delimiter: Delimiter) ![][]const u8 {
    var values = std.ArrayList([]const u8){};
    errdefer values.deinit(allocator);

    var value_buffer = std.ArrayList(u8){};
    defer value_buffer.deinit(allocator);

    var in_quotes = false;
    var i: usize = 0;

    while (i < input.len) {
        const char = input[i];

        if (char == BACKSLASH and i + 1 < input.len and in_quotes) {
            try value_buffer.append(allocator, char);
            i += 1;
            try value_buffer.append(allocator, input[i]);
            i += 1;
            continue;
        }

        if (char == DOUBLE_QUOTE) {
            in_quotes = !in_quotes;
            try value_buffer.append(allocator, char);
            i += 1;
            continue;
        }

        if (char == delimiter and !in_quotes) {
            const value = try allocator.dupe(u8, value_buffer.items);
            try values.append(allocator, value);
            value_buffer.clearRetainingCapacity();
            i += 1;
            continue;
        }

        try value_buffer.append(allocator, char);
        i += 1;
    }

    // Add last value
    if (value_buffer.items.len > 0 or values.items.len > 0) {
        const value = try allocator.dupe(u8, value_buffer.items);
        try values.append(allocator, value);
    }

    return try values.toOwnedSlice(allocator);
}

/// Maps row values to primitives
pub fn mapRowValuesToPrimitives(allocator: Allocator, values: []const []const u8) ![]JsonPrimitive {
    var primitives = std.ArrayList(JsonPrimitive){};
    errdefer primitives.deinit(allocator);

    for (values) |value| {
        const primitive = try parsePrimitiveToken(allocator, value);
        try primitives.append(allocator, primitive);
    }

    return try primitives.toOwnedSlice(allocator);
}

// #endregion

// #region Array content detection helpers

/// Checks if content is an array header after hyphen
pub fn isArrayHeaderAfterHyphen(content: []const u8) bool {
    return std.mem.indexOf(u8, content, &[_]u8{OPEN_BRACKET}) != null;
}

/// Checks if content is an object's first field after hyphen
pub fn isObjectFirstFieldAfterHyphen(content: []const u8) bool {
    return std.mem.indexOf(u8, content, &[_]u8{COLON}) != null;
}

// #endregion
