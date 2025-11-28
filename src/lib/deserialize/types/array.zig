const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("../Scanner.zig");
const Context = @import("../Context.zig");
const parseFieldValue = @import("value.zig").parseFieldValue;
const parsePrimitiveValue = @import("value.zig").parsePrimitiveValue;
const fieldMatches = @import("../../utils/case.zig").fieldCaseMatches;
const string = @import("string.zig");

/// Parse delimited field names, respecting quoted strings
fn parseDelimitedFields(input: []const u8, delimiter: u8, allocator: Allocator) ![][]const u8 {
    var fields = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (fields.items) |f| allocator.free(f);
        fields.deinit();
    }

    var value_buffer = std.array_list.Managed(u8).init(allocator);
    defer value_buffer.deinit();

    var in_quotes = false;
    var i: usize = 0;

    while (i < input.len) {
        const char = input[i];

        // Handle escape sequences in quoted strings
        if (char == '\\' and i + 1 < input.len and in_quotes) {
            try value_buffer.append(char);
            try value_buffer.append(input[i + 1]);
            i += 2;
            continue;
        }

        // Handle quote toggle
        if (char == '"') {
            in_quotes = !in_quotes;
            try value_buffer.append(char);
            i += 1;
            continue;
        }

        // Handle delimiter (only outside quotes)
        if (char == delimiter and !in_quotes) {
            const trimmed = std.mem.trim(u8, value_buffer.items, &std.ascii.whitespace);
            try fields.append(try allocator.dupe(u8, trimmed));
            value_buffer.clearRetainingCapacity();
            i += 1;
            continue;
        }

        // Regular character
        try value_buffer.append(char);
        i += 1;
    }

    // Add last field
    if (value_buffer.items.len > 0 or fields.items.len > 0) {
        const trimmed = std.mem.trim(u8, value_buffer.items, &std.ascii.whitespace);
        try fields.append(try allocator.dupe(u8, trimmed));
    }

    return fields.toOwnedSlice();
}

/// Parse a field name, unquoting and unescaping if needed
fn parseFieldName(field: []const u8, allocator: Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, field, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupe(u8, "");

    // If quoted, parse as string to unescape
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return try string.parseString(trimmed, allocator);
    }

    // Unquoted field name
    return try allocator.dupe(u8, trimmed);
}

/// TOON delimiter types per spec §11
pub const Delimiter = enum {
    comma, // default
    tab, // HTAB (U+0009)
    pipe, // "|"

    /// Get the character representation of the delimiter
    pub fn char(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .pipe => '|',
        };
    }

    /// Parse delimiter from bracket suffix: [N] = comma, [N\t] = tab, [N|] = pipe
    pub fn fromBracketContent(bracket_content: []const u8) Delimiter {
        if (bracket_content.len == 0) return .comma;
        const last_char = bracket_content[bracket_content.len - 1];
        return switch (last_char) {
            '\t' => .tab,
            '|' => .pipe,
            else => .comma,
        };
    }
};

pub fn parseTabularArray(
    comptime T: type,
    header: ArrayHeader,
    scanner: *Scanner,
    base_indent: usize,
    allocator: Allocator,
) ![]T {
    const fields = header.fields orelse return error.SyntaxError;

    // Verify T is a struct
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.TypeMismatch;

    var items = std.array_list.Managed(T).init(allocator);
    errdefer items.deinit();

    // Parse each row
    var row_count: usize = 0;
    while (scanner.peek()) |line| {
        // Must be indented more than header
        if (line.indent <= base_indent) break;

        // Parse row using header's active delimiter
        const item = try parseTabularRow(T, line.content, fields, header.delimiter, allocator);
        try items.append(item);

        _ = scanner.next();
        row_count += 1;
    }

    // Verify count matches header
    if (row_count != header.length) {
        return error.SyntaxError;
    }

    return items.toOwnedSlice();
}

pub const ArrayHeader = struct {
    key: ?[]const u8,
    length: u64,
    delimiter: Delimiter,
    fields: ?[]const []const u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        if (self.fields) |fields| for (fields) |field| allocator.free(field);
    }
};

/// Determine if this is a tabular array, primitive array, or list array
pub fn parseArray(
    comptime T: type,
    header: ArrayHeader,
    content_after_colon: []const u8,
    scanner: *Scanner,
    base_indent: usize,
    allocator: Allocator,
) ![]T {
    // If header has fields, it's tabular
    if (header.fields != null) {
        return try parseTabularArray(T, header, scanner, base_indent, allocator);
    }

    // Check if content is empty and next line starts with "- " (list format)
    const trimmed_content = std.mem.trim(u8, content_after_colon, &std.ascii.whitespace);
    if (trimmed_content.len == 0) {
        // Peek at next line to determine format
        if (scanner.peek()) |next_line| {
            if (next_line.indent > base_indent) {
                // Check if it starts with "- " (list format)
                if (std.mem.startsWith(u8, next_line.content, "- ") or
                    std.mem.eql(u8, next_line.content, "-")) {
                    return try parseListArray(T, header, scanner, base_indent, allocator);
                }
            }
        }
    }

    // Otherwise it's a primitive array on the same line
    return try parsePrimitiveArray(T, header, content_after_colon, allocator);
}

pub fn parsePrimitiveArray(
    comptime T: type,
    header: ArrayHeader,
    content_after_colon: []const u8,
    allocator: Allocator,
) ![]T {
    const type_info = @typeInfo(T);

    // Must be a primitive type
    const is_primitive = switch (type_info) {
        .int, .float, .bool => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        else => false,
    };

    if (!is_primitive) return error.TypeMismatch;

    var items = std.array_list.Managed(T).init(allocator);
    errdefer items.deinit();

    // Split by the active delimiter from header
    const delim_char = header.delimiter.char();
    var value_iter = std.mem.splitScalar(u8, content_after_colon, delim_char);
    var count: usize = 0;

    while (value_iter.next()) |val| {
        const trimmed = std.mem.trim(u8, val, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const parsed = try parsePrimitiveValue(T, trimmed, allocator);
        try items.append(parsed);
        count += 1;
    }

    // Verify count matches header
    if (count != header.length) {
        return error.SyntaxError;
    }

    return items.toOwnedSlice();
}

/// Parse a list array (expanded form with "- " prefix items)
pub fn parseListArray(
    comptime T: type,
    header: ArrayHeader,
    scanner: *Scanner,
    base_indent: usize,
    allocator: Allocator,
) ![]T {
    var items = std.array_list.Managed(T).init(allocator);
    errdefer items.deinit();

    var count: usize = 0;
    const expected_item_indent = base_indent + 2; // Items should be at base + indent size (2)

    while (scanner.peek()) |line| {
        // Stop if we've dedented back to or below base level
        if (line.indent <= base_indent) break;

        // Items should be at the expected indentation
        if (line.indent != expected_item_indent) {
            // Skip lines that are part of nested content (deeper indentation)
            if (line.indent > expected_item_indent) {
                _ = scanner.next();
                continue;
            }
            break;
        }

        // Check if this line starts with "- " or is just "-"
        const is_hyphen_line = std.mem.startsWith(u8, line.content, "- ") or
            std.mem.eql(u8, line.content, "-");

        if (!is_hyphen_line) {
            break;
        }

        // Consume the hyphen line
        _ = scanner.next();

        // Parse the item based on what follows the hyphen
        const item = try parseListItem(T, line.content, scanner, expected_item_indent, allocator);
        try items.append(item);
        count += 1;
    }

    // Verify count matches header
    if (count != header.length) {
        return error.SyntaxError;
    }

    return items.toOwnedSlice();
}

/// Parse a single list item (the content after "- ")
fn parseListItem(
    comptime T: type,
    hyphen_line: []const u8,
    scanner: *Scanner,
    item_indent: usize,
    allocator: Allocator,
) !T {
    // Handle empty item: just "-"
    if (std.mem.eql(u8, hyphen_line, "-")) {
        // Empty object - not fully supported yet
        // For now, return error
        return error.TypeMismatch;
    }

    // Extract content after "- "
    const content = hyphen_line[2..]; // Skip "- "
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);

    // Check if it's an inline array: "- [N]: ..."
    if (std.mem.startsWith(u8, trimmed, "[")) {
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            const before_colon = trimmed[0..colon_pos];
            if (std.mem.indexOfScalar(u8, before_colon, ']')) |_| {
                // This is an inline array item: "- [N]: v1,v2,..."
                return try parseListItemInlineArray(T, trimmed, allocator);
            }
        }
    }

    // Check if it's an object item: "- key: value"
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
        // This is an object with first field on hyphen line
        return try parseListItemObject(T, trimmed, colon_pos, scanner, item_indent, allocator);
    }

    // Otherwise it's a primitive value
    return try parsePrimitiveValue(T, trimmed, allocator);
}

/// Parse an inline array within a list item: "- [N]: v1,v2,..."
fn parseListItemInlineArray(
    comptime T: type,
    content: []const u8,
    allocator: Allocator,
) !T {
    const type_info = @typeInfo(T);
    if (type_info != .pointer) return error.TypeMismatch;
    const ptr_info = type_info.pointer;
    if (ptr_info.size != .slice) return error.TypeMismatch;

    const ChildT = ptr_info.child;

    // Parse the array header
    const colon_pos = std.mem.indexOfScalar(u8, content, ':') orelse return error.SyntaxError;
    const header_part = content[0..colon_pos];

    // Extract length and delimiter from [N<delim?>]
    const open_bracket = std.mem.indexOfScalar(u8, header_part, '[') orelse return error.SyntaxError;
    const close_bracket = std.mem.indexOfScalar(u8, header_part, ']') orelse return error.SyntaxError;
    const bracket_content = header_part[open_bracket + 1 .. close_bracket];

    const delimiter = Delimiter.fromBracketContent(bracket_content);

    // Extract length (strip delimiter suffix if present)
    const length_str = blk: {
        if (bracket_content.len > 0) {
            const last_char = bracket_content[bracket_content.len - 1];
            if (last_char == '\t' or last_char == '|') {
                break :blk bracket_content[0 .. bracket_content.len - 1];
            }
        }
        break :blk bracket_content;
    };
    const length = std.fmt.parseInt(usize, length_str, 10) catch return error.InvalidArrayLength;

    // Parse the values after the colon
    const values_part = std.mem.trim(u8, content[colon_pos + 1 ..], &std.ascii.whitespace);

    // Split by delimiter and parse
    var result = std.array_list.Managed(ChildT).init(allocator);
    errdefer result.deinit();

    const delim_char = delimiter.char();
    var value_iter = std.mem.splitScalar(u8, values_part, delim_char);
    var count: usize = 0;

    while (value_iter.next()) |val| {
        const trimmed_val = std.mem.trim(u8, val, &std.ascii.whitespace);
        if (trimmed_val.len == 0 and values_part.len > 0) {
            // Empty token
            const parsed = try parsePrimitiveValue(ChildT, "", allocator);
            try result.append(parsed);
            count += 1;
            continue;
        }
        if (trimmed_val.len == 0) continue;

        const parsed = try parsePrimitiveValue(ChildT, trimmed_val, allocator);
        try result.append(parsed);
        count += 1;
    }

    if (count != length) {
        return error.SyntaxError;
    }

    return result.toOwnedSlice();
}

/// Parse an object within a list item: "- key: value"
fn parseListItemObject(
    comptime T: type,
    hyphen_content: []const u8,
    colon_pos: usize,
    scanner: *Scanner,
    item_indent: usize,
    allocator: Allocator,
) !T {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.TypeMismatch;
    const struct_info = type_info.@"struct";

    var result: T = undefined;

    // Parse the first field from the hyphen line
    const first_key = std.mem.trim(u8, hyphen_content[0..colon_pos], &std.ascii.whitespace);
    const first_value_str = std.mem.trim(u8, hyphen_content[colon_pos + 1 ..], &std.ascii.whitespace);

    var first_field_matched = false;

    // Match the first field to a struct field
    inline for (struct_info.fields) |field| {
        if (try fieldMatches(first_key, field.name, allocator)) {
            const parsed_value = try parseFieldValue(field.type, first_value_str, allocator);
            @field(result, field.name) = parsed_value;
            first_field_matched = true;
            break;
        }
    }

    if (!first_field_matched) return error.UnknownField;

    // Parse remaining fields at item_indent + 2 (one level deeper than hyphen)
    const field_indent = item_indent + 2;
    while (scanner.peek()) |line| {
        // Stop if we've dedented back to or below item level
        if (line.indent <= item_indent) break;

        // Only process fields at the expected field indentation
        if (line.indent != field_indent) {
            _ = scanner.next();
            continue;
        }

        // Parse key-value pair
        const field_colon_pos = std.mem.indexOf(u8, line.content, ":") orelse {
            break; // No colon, end of object fields
        };

        const key_str = std.mem.trim(u8, line.content[0..field_colon_pos], " \t");
        const value_str = std.mem.trim(u8, line.content[field_colon_pos + 1 ..], " \t");

        _ = scanner.next();

        // Match to struct field
        var matched = false;
        inline for (struct_info.fields) |field| {
            if (try fieldMatches(key_str, field.name, allocator)) {
                const parsed_value = try parseFieldValue(field.type, value_str, allocator);
                @field(result, field.name) = parsed_value;
                matched = true;
                break;
            }
        }

        if (!matched) return error.UnknownField;
    }

    return result;
}

pub fn parseArrayHeader(content: []const u8, allocator: Allocator) !ArrayHeader {
    // Find the bracket, skipping any quoted sections
    var open_bracket: ?usize = null;
    var in_quotes = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const char = content[i];
        // Handle escapes in quotes
        if (char == '\\' and in_quotes and i + 1 < content.len) {
            i += 1; // Skip next character
            continue;
        }
        // Toggle quotes
        if (char == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        // Find bracket outside quotes
        if (char == '[' and !in_quotes) {
            open_bracket = i;
            break;
        }
    }

    const bracket_start = open_bracket orelse return error.SyntaxError;
    const close_bracket = std.mem.indexOfScalar(u8, content[bracket_start..], ']') orelse return error.SyntaxError;
    const close_bracket_abs = bracket_start + close_bracket;

    const key = std.mem.trim(u8, content[0..bracket_start], &std.ascii.whitespace);
    const bracket_content = content[bracket_start + 1 .. close_bracket_abs];

    // Parse delimiter from bracket content per spec §6
    // [N] = comma (default), [N\t] = tab, [N|] = pipe
    const delimiter = Delimiter.fromBracketContent(bracket_content);

    // Extract length (strip delimiter suffix if present)
    const length_str = blk: {
        if (bracket_content.len > 0) {
            const last_char = bracket_content[bracket_content.len - 1];
            if (last_char == '\t' or last_char == '|') {
                break :blk bracket_content[0 .. bracket_content.len - 1];
            }
        }
        break :blk bracket_content;
    };
    const length = std.fmt.parseInt(usize, length_str, 10) catch return error.InvalidArrayLength;

    // Check for field specification
    var fields: ?[][]const u8 = null;
    const after_bracket = content[close_bracket_abs + 1 ..];

    if (std.mem.indexOfScalar(u8, after_bracket, '{')) |open_brace_idx| {
        const close_brace = std.mem.indexOfScalar(u8, after_bracket, '}') orelse return error.SyntaxError;
        const fields_str = after_bracket[open_brace_idx + 1 .. close_brace];

        var field_list = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (field_list.items) |field| allocator.free(field);
            field_list.deinit();
        }

        // Parse fields using delimiter-aware splitting (handles quoted field names)
        // Per spec §6: fields use same delimiter as bracket, and quoted names MUST be unescaped
        const delim_char = delimiter.char();
        const parsed_fields = try parseDelimitedFields(fields_str, delim_char, allocator);
        defer {
            for (parsed_fields) |f| allocator.free(f);
            allocator.free(parsed_fields);
        }

        for (parsed_fields) |field| {
            // Parse field name (unquote and unescape if quoted)
            const field_name = try parseFieldName(field, allocator);
            try field_list.append(field_name);
        }

        fields = try field_list.toOwnedSlice();
    }

    return ArrayHeader{
        .key = key,
        .length = length,
        .delimiter = delimiter,
        .fields = fields,
    };
}
pub fn parseArrayField(
    comptime T: type,
    header: ArrayHeader,
    content_after_colon: []const u8,
    scanner: *Scanner,
    base_indent: usize,
    ctx: *Context,
) !T {
    const type_info = @typeInfo(T);

    // Must be a slice
    if (type_info != .pointer) return error.TypeMismatch;
    const ptr_info = type_info.pointer;
    if (ptr_info.size != .slice) return error.TypeMismatch;

    const ChildT = ptr_info.child;

    return try parseArray(
        ChildT,
        header,
        content_after_colon,
        scanner,
        base_indent,
        ctx.allocator,
    );
}

fn parseTabularRow(
    comptime T: type,
    row: []const u8,
    field_names: []const []const u8,
    delimiter: Delimiter,
    allocator: Allocator,
) !T {
    const struct_info = @typeInfo(T).@"struct";

    var result: T = undefined;

    // Split row by the active delimiter
    var values = std.array_list.Managed([]const u8).init(allocator);
    defer values.deinit();

    const delim_char = delimiter.char();
    var value_iter = std.mem.splitScalar(u8, row, delim_char);
    while (value_iter.next()) |val| {
        try values.append(std.mem.trim(u8, val, &std.ascii.whitespace));
    }

    if (values.items.len != field_names.len) {
        return error.SyntaxError;
    }

    // Match each field name to struct field and parse value
    for (field_names, values.items) |toon_field, val| {
        var matched = false;

        inline for (struct_info.fields) |field| {
            if (try fieldMatches(toon_field, field.name, allocator)) {
                const parsed_value = try parseFieldValue(field.type, val, allocator);
                @field(result, field.name) = parsed_value;
                matched = true;
                break;
            }
        }

        if (!matched) return error.UnknownField;
    }

    return result;
}
