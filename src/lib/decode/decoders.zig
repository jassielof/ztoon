const std = @import("std");
const types = @import("../types.zig");
const constants = @import("../constants.zig");
const errors = @import("../errors.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const validation = @import("validation.zig");

const Allocator = std.mem.Allocator;
const ArrayHeaderInfo = types.ArrayHeaderInfo;
const Depth = types.Depth;
const JsonArray = types.JsonArray;
const JsonObject = types.JsonObject;
const JsonPrimitive = types.JsonPrimitive;
const JsonValue = types.JsonValue;
const ParsedLine = types.ParsedLine;
const ResolvedDecodingOptions = types.ResolvedDecodingOptions;

const LineCursor = scanner.LineCursor;
const LIST_ITEM_PREFIX = constants.list_item_prefix;
const COLON = constants.colon;
const DOT = constants.dot;
const DEFAULT_DELIMITER = constants.default_delimiter;

// #region Entry decoding

/// Decodes JSON value from parsed lines
pub fn decodeValueFromLines(allocator: Allocator, cursor: *LineCursor, options: ResolvedDecodingOptions) !JsonValue {
    const first = cursor.peek() orelse return errors.DecodeError.NoContentToDecode;

    // Check for root array
    if (parser.isArrayHeaderAfterHyphen(first.content)) {
        const header_info = try parser.parseArrayHeaderLine(allocator, first.content, DEFAULT_DELIMITER);
        if (header_info) |info| {
            cursor.advance(); // Move past the header line
            return try decodeArrayFromHeader(allocator, info.header, info.inline_values, cursor, 0, options);
        }
    }

    // Check for single primitive value
    if (cursor.getLength() == 1 and !isKeyValueLine(first)) {
        const trimmed = std.mem.trim(u8, first.content, &std.ascii.whitespace);
        const primitive = try parser.parsePrimitiveToken(allocator, trimmed);
        return JsonValue{ .primitive = primitive };
    }

    // Default to object
    return try decodeObject(allocator, cursor, 0, options);
}

fn isKeyValueLine(line: ParsedLine) bool {
    const content = line.content;

    // Look for unquoted colon or quoted key followed by colon
    if (std.mem.startsWith(u8, content, "\"")) {
        // Quoted key - find the closing quote
        const closing_quote_index = parser.findClosingQuote(content, 0) orelse return false;
        // Check if colon exists after quoted key
        return std.mem.indexOfScalarPos(u8, content, closing_quote_index + 1, COLON) != null;
    } else {
        // Unquoted key - look for first colon
        return std.mem.indexOfScalar(u8, content, COLON) != null;
    }
}

// #endregion

// #region Object decoding

const DecodeKeyValueResult = struct {
    key: []const u8,
    value: JsonValue,
    follow_depth: Depth,
    is_quoted: bool,
};

fn decodeObject(allocator: Allocator, cursor: *LineCursor, base_depth: Depth, options: ResolvedDecodingOptions) errors.DecodeError!JsonValue {
    var obj = JsonObject.init(allocator);
    errdefer obj.deinit();

    // Detect the actual depth of the first field
    var computed_depth: ?Depth = null;

    while (!cursor.atEnd()) {
        const line = cursor.peek() orelse break;
        if (line.depth < base_depth) break;

        if (computed_depth == null and line.depth >= base_depth) {
            computed_depth = line.depth;
        }

        if (line.depth == computed_depth.?) {
            cursor.advance();
            const result = try decodeKeyValue(allocator, line.content, cursor, computed_depth.?, options);
            try obj.put(result.key, result.value);
        } else {
            break;
        }
    }

    return JsonValue{ .object = obj };
}

fn decodeKeyValue(
    allocator: Allocator,
    content: []const u8,
    cursor: *LineCursor,
    base_depth: Depth,
    options: ResolvedDecodingOptions,
) !DecodeKeyValueResult {
    // Check for array header first
    const array_header = try parser.parseArrayHeaderLine(allocator, content, DEFAULT_DELIMITER);
    if (array_header) |ah| {
        if (ah.header.key) |key| {
            const decoded_value = try decodeArrayFromHeader(allocator, ah.header, ah.inline_values, cursor, base_depth, options);
            return DecodeKeyValueResult{
                .key = key,
                .value = decoded_value,
                .follow_depth = base_depth + 1,
                .is_quoted = false,
            };
        }
    }

    // Regular key-value pair
    const key_result = try parser.parseKeyToken(allocator, content, 0);
    const rest = std.mem.trim(u8, content[key_result.end..], &std.ascii.whitespace);

    // No value after colon - expect nested object or empty
    if (rest.len == 0) {
        const next_line = cursor.peek();
        if (next_line != null and next_line.?.depth > base_depth) {
            const nested = try decodeObject(allocator, cursor, base_depth + 1, options);
            return DecodeKeyValueResult{
                .key = key_result.key,
                .value = nested,
                .follow_depth = base_depth + 1,
                .is_quoted = key_result.is_quoted,
            };
        }
        // Empty object
        const empty_obj = JsonObject.init(allocator);
        return DecodeKeyValueResult{
            .key = key_result.key,
            .value = JsonValue{ .object = empty_obj },
            .follow_depth = base_depth + 1,
            .is_quoted = key_result.is_quoted,
        };
    }

    // Inline primitive value
    const decoded_value = try parser.parsePrimitiveToken(allocator, rest);
    return DecodeKeyValueResult{
        .key = key_result.key,
        .value = JsonValue{ .primitive = decoded_value },
        .follow_depth = base_depth + 1,
        .is_quoted = key_result.is_quoted,
    };
}

// #endregion

// #region Array decoding

fn decodeArrayFromHeader(
    allocator: Allocator,
    header: ArrayHeaderInfo,
    inline_values: ?[]const u8,
    cursor: *LineCursor,
    base_depth: Depth,
    options: ResolvedDecodingOptions,
) errors.DecodeError!JsonValue {
    // Inline primitive array
    if (inline_values) |iv| {
        const primitives = try decodeInlinePrimitiveArray(allocator, header, iv, options);
        var array = JsonArray{};
        for (primitives) |prim| {
            try array.append(allocator, JsonValue{ .primitive = prim });
        }
        return JsonValue{ .array = array };
    }

    // Tabular array
    if (header.fields) |_| {
        return try decodeTabularArray(allocator, header, cursor, base_depth, options);
    }

    // List array
    return try decodeListArray(allocator, header, cursor, base_depth, options);
}

fn decodeInlinePrimitiveArray(
    allocator: Allocator,
    header: ArrayHeaderInfo,
    inline_values: []const u8,
    options: ResolvedDecodingOptions,
) ![]JsonPrimitive {
    const trimmed = std.mem.trim(u8, inline_values, &std.ascii.whitespace);

    if (trimmed.len == 0) {
        try validation.assertExpectedCount(0, header.length, "inline array items", options);
        return try allocator.alloc(JsonPrimitive, 0);
    }

    const values = try parser.parseDelimitedValues(allocator, inline_values, header.delimiter);
    defer allocator.free(values);

    const primitives = try parser.mapRowValuesToPrimitives(allocator, values);

    try validation.assertExpectedCount(primitives.len, header.length, "inline array items", options);

    return primitives;
}

fn decodeListArray(
    allocator: Allocator,
    header: ArrayHeaderInfo,
    cursor: *LineCursor,
    base_depth: Depth,
    options: ResolvedDecodingOptions,
) errors.DecodeError!JsonValue {
    var items = JsonArray{};
    errdefer items.deinit(allocator);

    const item_depth = base_depth + 1;
    var start_line: ?u64 = null;
    var end_line: ?u64 = null;

    while (!cursor.atEnd() and items.items.len < header.length) {
        const line = cursor.peek() orelse break;
        if (line.depth < item_depth) break;

        const is_list_item = std.mem.startsWith(u8, line.content, LIST_ITEM_PREFIX) or
            std.mem.eql(u8, line.content, "-");

        if (line.depth == item_depth and is_list_item) {
            if (start_line == null) {
                start_line = line.line_number;
            }
            end_line = line.line_number;

            const item = try decodeListItem(allocator, cursor, item_depth, options);
            try items.append(allocator, item);

            const current_line = cursor.current();
            if (current_line) |cl| {
                end_line = cl.line_number;
            }
        } else {
            break;
        }
    }

    try validation.assertExpectedCount(items.items.len, header.length, "list array items", options);

    // Strict mode validations
    if (options.strict and start_line != null and end_line != null) {
        try validation.validateNoBlankLinesInRange(
            start_line.?,
            end_line.?,
            cursor.getBlankLines(),
            options.strict,
            "list array",
        );
    }

    if (options.strict) {
        try validation.validateNoExtraListItems(cursor, item_depth, header.length);
    }

    return JsonValue{ .array = items };
}

fn decodeTabularArray(
    allocator: Allocator,
    header: ArrayHeaderInfo,
    cursor: *LineCursor,
    base_depth: Depth,
    options: ResolvedDecodingOptions,
) !JsonValue {
    var objects = JsonArray{};
    errdefer objects.deinit(allocator);

    const row_depth = base_depth + 1;
    var start_line: ?u64 = null;
    var end_line: ?u64 = null;

    while (!cursor.atEnd() and objects.items.len < header.length) {
        const line = cursor.peek() orelse break;
        if (line.depth < row_depth) break;

        if (line.depth == row_depth) {
            if (start_line == null) {
                start_line = line.line_number;
            }
            end_line = line.line_number;

            cursor.advance();
            const values = try parser.parseDelimitedValues(allocator, line.content, header.delimiter);
            defer allocator.free(values);

            try validation.assertExpectedCount(values.len, header.fields.?.len, "tabular row values", options);

            const primitives = try parser.mapRowValuesToPrimitives(allocator, values);
            defer allocator.free(primitives);

            var obj = JsonObject.init(allocator);

            for (header.fields.?, 0..) |field, i| {
                try obj.put(field, JsonValue{ .primitive = primitives[i] });
            }

            try objects.append(allocator, JsonValue{ .object = obj });
        } else {
            break;
        }
    }

    try validation.assertExpectedCount(objects.items.len, header.length, "tabular rows", options);

    // Strict mode validations
    if (options.strict and start_line != null and end_line != null) {
        try validation.validateNoBlankLinesInRange(
            start_line.?,
            end_line.?,
            cursor.getBlankLines(),
            options.strict,
            "tabular array",
        );
    }

    if (options.strict) {
        try validation.validateNoExtraTabularRows(cursor, row_depth, header);
    }

    return JsonValue{ .array = objects };
}

// #endregion

// #region List item decoding

fn decodeListItem(
    allocator: Allocator,
    cursor: *LineCursor,
    base_depth: Depth,
    options: ResolvedDecodingOptions,
) !JsonValue {
    const line = cursor.next() orelse return errors.DecodeError.NoContentToDecode;

    // Empty list item should be an empty object
    if (std.mem.eql(u8, line.content, "-")) {
        const empty_obj = JsonObject.init(allocator);
        return JsonValue{ .object = empty_obj };
    }

    var after_hyphen: []const u8 = undefined;
    if (std.mem.startsWith(u8, line.content, LIST_ITEM_PREFIX)) {
        after_hyphen = line.content[LIST_ITEM_PREFIX.len..];
    } else {
        return errors.ParseError.SyntaxError;
    }

    // Empty content after list item should also be an empty object
    const trimmed = std.mem.trim(u8, after_hyphen, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        const empty_obj = JsonObject.init(allocator);
        return JsonValue{ .object = empty_obj };
    }

    // Check for array header after hyphen
    if (parser.isArrayHeaderAfterHyphen(after_hyphen)) {
        const array_header = try parser.parseArrayHeaderLine(allocator, after_hyphen, DEFAULT_DELIMITER);
        if (array_header) |ah| {
            return try decodeArrayFromHeader(allocator, ah.header, ah.inline_values, cursor, base_depth, options);
        }
    }

    // Check for object first field after hyphen
    if (parser.isObjectFirstFieldAfterHyphen(after_hyphen)) {
        return try decodeObjectFromListItem(allocator, line, cursor, base_depth, options);
    }

    // Primitive value
    const primitive = try parser.parsePrimitiveToken(allocator, after_hyphen);
    return JsonValue{ .primitive = primitive };
}

fn decodeObjectFromListItem(
    allocator: Allocator,
    first_line: ParsedLine,
    cursor: *LineCursor,
    base_depth: Depth,
    options: ResolvedDecodingOptions,
) errors.DecodeError!JsonValue {
    const after_hyphen = first_line.content[LIST_ITEM_PREFIX.len..];
    const result = try decodeKeyValue(allocator, after_hyphen, cursor, base_depth, options);

    var obj = JsonObject.init(allocator);
    try obj.put(result.key, result.value);

    // Read subsequent fields
    while (!cursor.atEnd()) {
        const line = cursor.peek() orelse break;
        if (line.depth < result.follow_depth) break;

        if (line.depth == result.follow_depth and !std.mem.startsWith(u8, line.content, LIST_ITEM_PREFIX)) {
            cursor.advance();
            const kv_result = try decodeKeyValue(allocator, line.content, cursor, result.follow_depth, options);
            try obj.put(kv_result.key, kv_result.value);
        } else {
            break;
        }
    }

    return JsonValue{ .object = obj };
}

// #endregion
