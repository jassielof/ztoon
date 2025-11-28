const std = @import("std");
const Allocator = std.mem.Allocator;
const number = @import("number.zig");
const parseStruct = @import("object.zig").parseStruct;
const boolean = @import("boolean.zig");
const isNull = @import("null.zig").isNull;
const string = @import("string.zig");
const Scanner = @import("../Scanner.zig");
const Context = @import("../Context.zig");
const Value = @import("../../Value.zig").Value;
const array = @import("array.zig");

/// Parse a primitive value (int, float, bool, string) from a given content.
pub fn parsePrimitiveValue(comptime T: type, val: []const u8, allocator: Allocator) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => try number.parseInt(T, val),
        .float => try number.parseFloat(T, val),
        .bool => try boolean.parseBool(val),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try string.parseString(val, allocator);
            }
            return error.TypeMismatch;
        },
        else => error.TypeMismatch,
    };
}

/// Parse a nested value (struct, array, etc.) from the scanner.
pub fn parseNestedValue(
    comptime T: type,
    scanner: *Scanner,
    parent_indent: usize,
    ctx: *Context,
) !T {
    const next_line = scanner.peek() orelse return error.UnexpectedEof;

    // Nested content must be indented more
    if (next_line.indent <= parent_indent) return error.InvalidIndentation;

    return parseValue(T, scanner, next_line.indent, ctx);
}

/// Parse an inline value (int, float, bool, string, optional) from a given content.
pub fn parseInlineValue(
    comptime T: type,
    content: []const u8,
    ctx: *Context,
) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => try number.parseInt(T, content),
        .float => try number.parseFloat(T, content),
        .bool => try boolean.parseBool(content),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try string.parseString(content, ctx.allocator);
            }
            return error.TypeMismatch;
        },
        .optional => |opt| blk: {
            if (isNull(content)) {
                break :blk null;
            }
            break :blk try parseInlineValue(opt.child, content, ctx);
        },
        else => error.TypeMismatch,
    };
}

/// Parse a value of type T from the scanner, handling both inline and nested values.
pub fn parseValue(comptime T: type, scanner: *Scanner, base_indent: usize, ctx: *Context) !T {
    if (ctx.depth >= ctx.options.max_depth) return error.SyntaxError;
    ctx.depth += 1;
    defer ctx.depth -= 1;
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .@"struct" => try parseStruct(T, scanner, base_indent, ctx),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    // String - read inline
                    const line = scanner.peek() orelse return error.UnexpectedEof;
                    _ = scanner.next();
                    break :blk try string.parseString(line.content, ctx.allocator);
                }
                // Array/slice - should be handled by parseStruct for struct fields
                return error.TypeMismatch;
            }
            return error.TypeMismatch;
        },
        .int, .comptime_int => blk: {
            const line = scanner.peek() orelse return error.UnexpectedEof;
            _ = scanner.next();
            break :blk try number.parseInt(T, line.content);
        },

        .float, .comptime_float => blk: {
            const line = scanner.peek() orelse return error.UnexpectedEof;
            _ = scanner.next();
            break :blk try number.parseFloat(T, line.content);
        },

        .bool => blk: {
            const line = scanner.peek() orelse return error.UnexpectedEof;
            _ = scanner.next();
            break :blk try boolean.parseBool(line.content);
        },

        .optional => |opt| blk: {
            const line = scanner.peek() orelse return null;
            if (isNull(line.content)) {
                _ = scanner.next();
                break :blk null;
            }
            break :blk try parseValue(opt.child, scanner, base_indent, ctx);
        },
        .@"union" => |u| blk: {
            // Check if this is our Value type or std.json.Value
            if (u.tag_type != null) {
                if (T == Value) {
                    break :blk try parseDynamicValue(scanner, base_indent, ctx);
                } else if (T == std.json.Value) {
                    break :blk try parseStdJsonValue(scanner, base_indent, ctx);
                }
            }
            @compileError("Cannot parse union type: " ++ @typeName(T));
        },
        else => @compileError("Cannot parse type: " ++ @typeName(T)),
    };
}

/// Parse a root array from the scanner (for Value type)
fn parseRootArray(scanner: *Scanner, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, InvalidArrayLength, SyntaxError, UnexpectedEof })!Value {
    const line = scanner.peek() orelse return error.SyntaxError;

    // Parse the array header
    const header = try array.parseArrayHeader(line.content, ctx.allocator);
    defer header.deinit(ctx.allocator);

    // Find the content after the colon
    const colon_pos = std.mem.indexOfScalar(u8, line.content, ':') orelse return error.SyntaxError;
    const content_after_colon = std.mem.trim(u8, line.content[colon_pos + 1 ..], " \t");

    // Consume the array header line
    _ = scanner.next();

    // Create the array using a managed list
    var items = std.array_list.Managed(Value).init(ctx.allocator);
    errdefer {
        for (items.items) |*item| {
            item.deinit(ctx.allocator);
        }
        items.deinit();
    }

    // Track first and last item line numbers for blank line validation
    var first_item_line: usize = 0;
    var last_item_line: usize = 0;

    // If this is a tabular array (has fields), parse tabular rows
    if (header.fields) |fields| {
        const row_indent: usize = 2; // Root tabular arrays have rows at indent 2
        var count: usize = 0;

        while (scanner.peek()) |next_line| {
            if (next_line.indent < row_indent) break;
            if (next_line.indent != row_indent) {
                _ = scanner.next();
                continue;
            }

            // Track line numbers
            if (first_item_line == 0) first_item_line = next_line.number;
            last_item_line = next_line.number;

            // Parse the row using delimiter-aware splitting
            const delim_char = header.delimiter.char();
            const row_values = try parseDelimitedValues(next_line.content, delim_char, ctx.allocator);
            defer {
                for (row_values) |rv| {
                    ctx.allocator.free(rv);
                }
                ctx.allocator.free(row_values);
            }

            // Validate row width matches field count
            if (row_values.len != fields.len) {
                return error.SyntaxError;
            }

            // Create object from fields and values
            var obj = Value.Object.init(ctx.allocator);
            errdefer {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    ctx.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(ctx.allocator);
                }
                obj.deinit();
            }

            for (fields, 0..) |field, fi| {
                const field_key = try ctx.allocator.dupe(u8, field);
                const field_value = try parsePrimitiveToValue(row_values[fi], ctx);
                try obj.put(field_key, field_value);
            }

            try items.append(.{ .object = obj });
            _ = scanner.next();
            count += 1;
        }

        // Verify count matches header
        if (count != header.length) {
            return error.SyntaxError;
        }

        // Strict mode: check for blank lines inside array (§14.4)
        if (ctx.options.strict orelse true) {
            if (first_item_line > 0 and last_item_line > first_item_line) {
                if (scanner.hasBlankLinesBetween(first_item_line, last_item_line + 1)) {
                    return error.SyntaxError;
                }
            }
        }
    } else if (content_after_colon.len == 0) {
        // List array (no inline content, no fields)
        var count: usize = 0;
        const item_indent: usize = 2; // Root arrays have items at indent 2

        while (scanner.peek()) |next_line| {
            if (next_line.indent < item_indent) break;
            if (next_line.indent != item_indent) {
                _ = scanner.next();
                continue;
            }

            // Check if this is a list item (starts with "- ")
            const is_list_item = std.mem.startsWith(u8, next_line.content, "- ") or
                std.mem.eql(u8, next_line.content, "-");

            if (is_list_item) {
                // Track line numbers
                if (first_item_line == 0) first_item_line = next_line.number;
                last_item_line = next_line.number;

                // Parse list item: consume the "- " prefix and parse the content
                _ = scanner.next();

                // Handle empty item: just "-"
                if (std.mem.eql(u8, next_line.content, "-")) {
                    try items.append(.{ .object = Value.Object.init(ctx.allocator) });
                    count += 1;
                    continue;
                }

                // Extract content after "- "
                const after_hyphen = next_line.content[2..]; // Skip "- "
                const trimmed = std.mem.trim(u8, after_hyphen, &std.ascii.whitespace);

                // Check if it's an inline object with first field on hyphen line
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |_| {
                    // This is an object - parse first field and any subsequent fields
                    const item_obj = try parseListItemObject(next_line.content, scanner, item_indent, ctx);
                    try items.append(.{ .object = item_obj });
                } else {
                    // Primitive value
                    const value = try parsePrimitiveToValue(trimmed, ctx);
                    try items.append(value);
                }

                count += 1;
            } else {
                break; // Not a list item, stop parsing
            }
        }

        // Verify count matches header
        if (count != header.length) {
            return error.SyntaxError;
        }

        // Strict mode: check for blank lines inside array (§14.4)
        if (ctx.options.strict orelse true) {
            if (first_item_line > 0 and last_item_line > first_item_line) {
                if (scanner.hasBlankLinesBetween(first_item_line, last_item_line + 1)) {
                    return error.SyntaxError;
                }
            }
        }
    } else {
        // Parse inline primitive array values (no blank line check needed - single line)
        const delim_char = header.delimiter.char();
        const parsed_values = try parseDelimitedValues(content_after_colon, delim_char, ctx.allocator);
        defer {
            for (parsed_values) |v| {
                ctx.allocator.free(v);
            }
            ctx.allocator.free(parsed_values);
        }

        for (parsed_values) |v| {
            // Empty tokens decode to empty string (per spec §9.1)
            const value = try parsePrimitiveToValue(v, ctx);
            try items.append(value);
        }

        // Verify count matches header
        if (items.items.len != header.length) {
            return error.SyntaxError;
        }
    }

    // Convert managed list to ArrayList
    const owned_slice = try items.toOwnedSlice();
    const result = std.ArrayList(Value){ .items = owned_slice, .capacity = owned_slice.len };
    return .{ .array = result };
}

/// Parse a list item object from a hyphen line and subsequent fields
fn parseListItemObject(hyphen_line: []const u8, scanner: *Scanner, item_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!Value.Object {
    // Extract content after "- "
    const after_hyphen = hyphen_line[2..]; // Skip "- "
    const trimmed = std.mem.trim(u8, after_hyphen, &std.ascii.whitespace);

    // Parse the first field from the hyphen line
    const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidEscapeSequence;
    const first_key = std.mem.trim(u8, trimmed[0..colon_pos], &std.ascii.whitespace);
    const first_value_str = std.mem.trim(u8, trimmed[colon_pos + 1 ..], &std.ascii.whitespace);

    var obj = Value.Object.init(ctx.allocator);
    errdefer {
        var it = obj.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(ctx.allocator);
        }
        obj.deinit();
    }

    // Add the first field
    const key = try ctx.allocator.dupe(u8, first_key);
    const value = if (first_value_str.len > 0)
        try parsePrimitiveToValue(first_value_str, ctx)
    else
        .null;
    try obj.put(key, value);

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

        // Add field to object
        const field_key = try ctx.allocator.dupe(u8, key_str);
        const field_value = if (value_str.len > 0)
            try parsePrimitiveToValue(value_str, ctx)
        else
            .null;
        try obj.put(field_key, field_value);
    }

    return obj;
}

/// Parse delimited values while respecting quoted strings
fn parseDelimitedValues(input: []const u8, delimiter: u8, allocator: Allocator) ![][]const u8 {
    var values = std.array_list.Managed([]const u8).init(allocator);
    errdefer values.deinit();

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
            try values.append(try allocator.dupe(u8, trimmed));
            value_buffer.clearRetainingCapacity();
            i += 1;
            continue;
        }

        // Regular character
        try value_buffer.append(char);
        i += 1;
    }

    // Add last value
    if (value_buffer.items.len > 0 or values.items.len > 0) {
        const trimmed = std.mem.trim(u8, value_buffer.items, &std.ascii.whitespace);
        try values.append(try allocator.dupe(u8, trimmed));
    }

    return values.toOwnedSlice();
}

/// Parse a primitive value and convert it to a Value
fn parsePrimitiveToValue(content: []const u8, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!Value {
    // Check for null
    if (isNull(content)) return .null;

    // Check for boolean
    if (boolean.parseBool(content)) |b| {
        return .{ .bool = b };
    } else |_| {}

    // Check for number
    if (number.parseInt(i64, content)) |i| {
        return .{ .integer = i };
    } else |_| {}

    if (number.parseFloat(f64, content)) |f| {
        return .{ .float = f };
    } else |_| {}

    // Otherwise, it's a string
    const str = try string.parseString(content, ctx.allocator);
    return .{ .string = str };
}

/// Parse a dynamic value (TOONZ Value type) from the scanner.
fn parseDynamicValue(scanner: *Scanner, base_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, TypeMismatch, InvalidArrayLength, SyntaxError, UnexpectedEof })!Value {
    // Root form detection (§5): only applies at depth 0
    if (base_indent == 0) {
        // Check for empty document
        const first_line = scanner.peek() orelse {
            // Empty document → empty object
            return .{ .object = Value.Object.init(ctx.allocator) };
        };

        // Check for root array header: [N]:
        if (first_line.content.len > 0 and first_line.content[0] == '[') {
            if (std.mem.indexOfScalar(u8, first_line.content, ':')) |colon_pos| {
                const before_colon = first_line.content[0..colon_pos];
                if (std.mem.indexOfScalar(u8, before_colon, ']')) |_| {
                    // This is a root array header [N]:
                    // Parse it as an inline primitive array
                    return try parseRootArray(scanner, ctx);
                }
            }
        }

        // Check for single primitive (exactly one line, no colon)
        if (std.mem.indexOfScalar(u8, first_line.content, ':') == null) {
            // Count total non-empty lines at depth 0
            var line_count: usize = 0;
            var temp_scanner = scanner.*;
            while (temp_scanner.peek()) |peek_line| {
                if (peek_line.indent == 0) {
                    line_count += 1;
                }
                _ = temp_scanner.next();
            }

            if (line_count == 1) {
                // Single primitive
                _ = scanner.next();
                const content = std.mem.trim(u8, first_line.content, " \t");
                return try parseSinglePrimitive(content, ctx);
            } else {
                // Multiple depth-0 lines without colons - invalid per §5
                // "if there are two or more non-empty depth-0 lines that are neither
                // headers nor key-value lines, the document is invalid"
                return error.SyntaxError;
            }
        }
    }

    const line = scanner.peek() orelse return .null;

    // If this line has a colon, it's an object (key-value structure)
    if (std.mem.indexOfScalar(u8, line.content, ':')) |_| {
        return try parseDynamicObject(scanner, base_indent, ctx);
    }

    const content = std.mem.trim(u8, line.content, " \t");

    // Check for null
    if (isNull(content)) {
        _ = scanner.next();
        return .null;
    }

    // Check for boolean
    if (boolean.parseBool(content)) |b| {
        _ = scanner.next();
        return .{ .bool = b };
    } else |_| {}

    // Check for number
    if (number.parseInt(i64, content)) |i| {
        _ = scanner.next();
        return .{ .integer = i };
    } else |_| {}

    if (number.parseFloat(f64, content)) |f| {
        _ = scanner.next();
        return .{ .float = f };
    } else |_| {}

    // Otherwise, it's a string
    _ = scanner.next();
    const str = try string.parseString(content, ctx.allocator);
    return .{ .string = str };
}

/// Parse a single primitive value (for root form detection)
fn parseSinglePrimitive(content: []const u8, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!Value {
    if (isNull(content)) return .null;

    if (boolean.parseBool(content)) |b| {
        return .{ .bool = b };
    } else |_| {}

    if (number.parseInt(i64, content)) |i| {
        return .{ .integer = i };
    } else |_| {}

    if (number.parseFloat(f64, content)) |f| {
        return .{ .float = f };
    } else |_| {}

    const str = try string.parseString(content, ctx.allocator);
    return .{ .string = str };
}

/// Find the first colon that's not inside quotes
fn findUnquotedColon(content: []const u8) ?usize {
    var in_quotes = false;
    var i: usize = 0;
    while (i < content.len) {
        const char = content[i];
        // Handle escape sequences in quoted strings
        if (char == '\\' and i + 1 < content.len and in_quotes) {
            i += 2;
            continue;
        }
        // Handle quote toggle
        if (char == '"') {
            in_quotes = !in_quotes;
            i += 1;
            continue;
        }
        // Found unquoted colon
        if (char == ':' and !in_quotes) {
            return i;
        }
        i += 1;
    }
    return null;
}

/// Parse a dynamic object (for Value type)
fn parseDynamicObject(scanner: *Scanner, base_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!Value {
    var object = Value.Object.init(ctx.allocator);
    errdefer {
        var it = object.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(ctx.allocator);
        }
        object.deinit();
    }

    while (scanner.peek()) |line| {
        // Stop if dedented (exited this object)
        if (line.indent < base_indent) break;

        // Skip if too indented (should have been consumed by nested parse)
        if (line.indent > base_indent) {
            _ = scanner.next();
            continue;
        }

        // Parse key-value pair at this level
        // Find colon outside quotes (important for headers with quoted field names)
        const colon_pos = findUnquotedColon(line.content) orelse {
            _ = scanner.next();
            continue;
        };

        const key_str = std.mem.trim(u8, line.content[0..colon_pos], " \t");

        // Check if this is an array header (key contains [...])
        // But ignore brackets if the entire key is quoted
        const is_quoted_key = key_str.len >= 2 and key_str[0] == '"' and key_str[key_str.len - 1] == '"';
        const has_array_header = !is_quoted_key and std.mem.indexOfScalar(u8, key_str, '[') != null;

        // Handle array keys like "friends[3]" - extract key name before bracket
        var key_name: []const u8 = undefined;
        if (is_quoted_key) {
            // Quoted key - parse and unescape
            key_name = try string.parseString(key_str, ctx.allocator);
        } else if (std.mem.indexOfScalar(u8, key_str, '[')) |bracket_pos| {
            // Array key - extract name before bracket
            key_name = try ctx.allocator.dupe(u8, key_str[0..bracket_pos]);
        } else {
            // Plain key
            key_name = try ctx.allocator.dupe(u8, key_str);
        }
        errdefer ctx.allocator.free(key_name);

        const value_str = std.mem.trim(u8, line.content[colon_pos + 1 ..], " \t");

        // Consume the line
        _ = scanner.next();

        // Check if value is inline or nested
        var val: Value = undefined;
        if (value_str.len > 0) {
            // If the key has an array header, parse as inline array with validation
            if (has_array_header) {
                // Parse array header from the full line to get length and delimiter
                const header = try array.parseArrayHeader(line.content, ctx.allocator);
                defer header.deinit(ctx.allocator);

                // Parse inline primitive array values
                const delim_char = header.delimiter.char();
                const parsed_values = try parseDelimitedValues(value_str, delim_char, ctx.allocator);
                defer {
                    for (parsed_values) |v| {
                        ctx.allocator.free(v);
                    }
                    ctx.allocator.free(parsed_values);
                }

                var items = std.array_list.Managed(Value).init(ctx.allocator);
                defer items.deinit();
                errdefer {
                    for (items.items) |item| {
                        item.deinit(ctx.allocator);
                    }
                }

                for (parsed_values) |v| {
                    // Empty tokens decode to empty string (per spec §9.1)
                    const value = try parsePrimitiveToValue(v, ctx);
                    try items.append(value);
                }

                const count = items.items.len;

                // Verify count matches header
                if (count != header.length) {
                    // Clean up before returning error
                    for (items.items) |item| {
                        item.deinit(ctx.allocator);
                    }
                    return error.SyntaxError;
                }

                // Convert to array
                const owned_slice = try items.toOwnedSlice();
                const result = std.ArrayList(Value){ .items = owned_slice, .capacity = owned_slice.len };
                val = .{ .array = result };
            } else {
                // Inline value (not an array)
                if (isNull(value_str)) {
                    val = .null;
                } else if (boolean.parseBool(value_str)) |b| {
                    val = .{ .bool = b };
                } else |_| {
                    if (number.parseInt(i64, value_str)) |i| {
                        val = .{ .integer = i };
                    } else |_| {
                        if (number.parseFloat(f64, value_str)) |f| {
                            val = .{ .float = f };
                        } else |_| {
                            const str = try string.parseString(value_str, ctx.allocator);
                            val = .{ .string = str };
                        }
                    }
                }
            }
        } else {
            // Empty value - could be a nested object/array or null
            if (has_array_header) {
                // Array header with no inline values - parse as list or tabular array
                const header = try array.parseArrayHeader(line.content, ctx.allocator);
                defer header.deinit(ctx.allocator);

                // Tabular arrays - parse rows and validate field counts
                if (header.fields) |fields| {
                    var items = std.array_list.Managed(Value).init(ctx.allocator);
                    errdefer {
                        for (items.items) |*item| {
                            item.deinit(ctx.allocator);
                        }
                        items.deinit();
                    }

                    const row_indent = base_indent + 2;
                    var count: usize = 0;
                    var first_item_line: usize = 0;
                    var last_item_line: usize = 0;

                    while (scanner.peek()) |next_line| {
                        if (next_line.indent < row_indent) break;
                        if (next_line.indent != row_indent) {
                            _ = scanner.next();
                            continue;
                        }

                        // Track line numbers for blank line validation
                        if (first_item_line == 0) first_item_line = next_line.number;
                        last_item_line = next_line.number;

                        // Parse the row using delimiter-aware splitting
                        const delim_char = header.delimiter.char();
                        const row_values = try parseDelimitedValues(next_line.content, delim_char, ctx.allocator);
                        defer {
                            for (row_values) |rv| {
                                ctx.allocator.free(rv);
                            }
                            ctx.allocator.free(row_values);
                        }

                        // Validate row width matches field count
                        if (row_values.len != fields.len) {
                            return error.SyntaxError;
                        }

                        // Create object from fields and values
                        var obj = Value.Object.init(ctx.allocator);
                        errdefer {
                            var it = obj.iterator();
                            while (it.next()) |entry| {
                                ctx.allocator.free(entry.key_ptr.*);
                                entry.value_ptr.deinit(ctx.allocator);
                            }
                            obj.deinit();
                        }

                        for (fields, 0..) |field, fi| {
                            const field_key = try ctx.allocator.dupe(u8, field);
                            const field_value = try parsePrimitiveToValue(row_values[fi], ctx);
                            try obj.put(field_key, field_value);
                        }

                        try items.append(.{ .object = obj });
                        _ = scanner.next();
                        count += 1;
                    }

                    // Verify count matches header
                    if (count != header.length) {
                        return error.SyntaxError;
                    }

                    // Strict mode: check for blank lines inside array (§14.4)
                    if (ctx.options.strict orelse true) {
                        if (first_item_line > 0 and last_item_line > first_item_line) {
                            if (scanner.hasBlankLinesBetween(first_item_line, last_item_line + 1)) {
                                return error.SyntaxError;
                            }
                        }
                    }

                    const owned_slice = try items.toOwnedSlice();
                    const result = std.ArrayList(Value){ .items = owned_slice, .capacity = owned_slice.len };
                    val = .{ .array = result };
                } else {
                    // List array - validate count
                    var items = std.array_list.Managed(Value).init(ctx.allocator);
                    defer items.deinit();
                    errdefer {
                        for (items.items) |item| {
                            item.deinit(ctx.allocator);
                        }
                    }

                    const item_indent = base_indent + 2;
                    var count: usize = 0;
                    var first_item_line: usize = 0;
                    var last_item_line: usize = 0;

                    while (scanner.peek()) |next_line| {
                        if (next_line.indent < item_indent) break;
                        if (next_line.indent != item_indent) {
                            _ = scanner.next();
                            continue;
                        }

                        // Check if this is a list item
                        const is_list_item = std.mem.startsWith(u8, next_line.content, "- ") or
                            std.mem.eql(u8, next_line.content, "-");

                        if (is_list_item) {
                            // Track line numbers for blank line validation
                            if (first_item_line == 0) first_item_line = next_line.number;
                            last_item_line = next_line.number;

                            _ = scanner.next();
                            if (std.mem.eql(u8, next_line.content, "-")) {
                                try items.append(.{ .object = Value.Object.init(ctx.allocator) });
                            } else {
                                const after_hyphen = next_line.content[2..];
                                const trimmed = std.mem.trim(u8, after_hyphen, &std.ascii.whitespace);
                                const value = try parsePrimitiveToValue(trimmed, ctx);
                                try items.append(value);
                            }
                            count += 1;
                            // Don't break early - we need to count all items to detect mismatches
                        } else {
                            break;
                        }
                    }

                    // Verify count matches header
                    if (count != header.length) {
                        for (items.items) |item| {
                            item.deinit(ctx.allocator);
                        }
                        return error.SyntaxError;
                    }

                    // Strict mode: check for blank lines inside array (§14.4)
                    if (ctx.options.strict orelse true) {
                        if (first_item_line > 0 and last_item_line > first_item_line) {
                            if (scanner.hasBlankLinesBetween(first_item_line, last_item_line + 1)) {
                                for (items.items) |item| {
                                    item.deinit(ctx.allocator);
                                }
                                return error.SyntaxError;
                            }
                        }
                    }

                    const owned_slice = try items.toOwnedSlice();
                    const result = std.ArrayList(Value){ .items = owned_slice, .capacity = owned_slice.len };
                    val = .{ .array = result };
                }
            } else {
                // Nested value (not an array)
                const peek_next = scanner.peek();
                if (peek_next) |next| {
                    if (next.indent > base_indent) {
                        val = try parseDynamicNestedValue(scanner, base_indent, ctx);
                    } else {
                        val = .null;
                    }
                } else {
                    val = .null;
                }
            }
        }

        try object.put(key_name, val);
    }

    return .{ .object = object };
}

/// Parse a nested value (for toonz.Value)
/// This is called when we have `key:` with empty value and need to parse nested content.
/// The nested content must be either:
/// - Key-value pairs (nested object) - has colon
/// - If it doesn't have a colon, it's an error (missing colon in key-value context)
fn parseDynamicNestedValue(scanner: *Scanner, parent_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!Value {
    const line = scanner.peek() orelse return .null;
    const child_indent = line.indent;

    if (child_indent <= parent_indent) return .null;

    // If this line has a colon, it's a nested object
    if (std.mem.indexOfScalar(u8, line.content, ':')) |_| {
        return try parseDynamicObject(scanner, child_indent, ctx);
    }

    // No colon found - this is an error (missing colon in key-value context)
    // Per spec §14.2: "Missing colon in key context" must error
    return error.SyntaxError;
}

/// Parse a root array from the scanner (for std.json.Value)
fn parseRootArrayStdJson(scanner: *Scanner, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, InvalidArrayLength, SyntaxError, UnexpectedEof })!std.json.Value {
    const line = scanner.peek() orelse return error.SyntaxError;

    // Parse the array header
    const header = try array.parseArrayHeader(line.content, ctx.allocator);
    defer header.deinit(ctx.allocator);

    // Find the content after the colon
    const colon_pos = std.mem.indexOfScalar(u8, line.content, ':') orelse return error.SyntaxError;
    const content_after_colon = std.mem.trim(u8, line.content[colon_pos + 1 ..], " \t");

    // Consume the array header line
    _ = scanner.next();

    // Create the array using a managed list
    var items = std.array_list.Managed(std.json.Value).init(ctx.allocator);
    errdefer items.deinit();

    // If this is a tabular array or list array (no inline content), parse from following lines
    if (content_after_colon.len == 0 or header.fields != null) {
        // For root arrays with nested content, parse each item at indent level 1
        var count: usize = 0;
        const item_indent: usize = 2; // Root arrays have items at indent 2

        while (scanner.peek()) |next_line| {
            if (next_line.indent < item_indent) break;
            if (next_line.indent != item_indent) {
                _ = scanner.next();
                continue;
            }

            // Parse the item as a dynamic value at this indent level
            const item = try parseStdJsonNestedValue(scanner, 0, ctx);
            try items.append(item);
            count += 1;

            if (count >= header.length) break;
        }

        // Verify count matches header
        if (count != header.length) {
            return error.SyntaxError;
        }
    } else {
        // Parse inline primitive array values
        const delim_char = header.delimiter.char();
        const parsed_values = try parseDelimitedValues(content_after_colon, delim_char, ctx.allocator);
        defer {
            for (parsed_values) |v| {
                ctx.allocator.free(v);
            }
            ctx.allocator.free(parsed_values);
        }

        for (parsed_values) |v| {
            // Empty tokens decode to empty string (per spec §9.1)
            const value = try parsePrimitiveToStdJsonValue(v, ctx);
            try items.append(value);
        }

        // Verify count matches header
        if (items.items.len != header.length) {
            return error.SyntaxError;
        }
    }

    // Convert managed list to std.json.Array
    const owned_slice = try items.toOwnedSlice();
    const result = std.json.Array{ .items = owned_slice, .capacity = owned_slice.len, .allocator = ctx.allocator };
    return .{ .array = result };
}

/// Parse a primitive value and convert it to a std.json.Value
fn parsePrimitiveToStdJsonValue(content: []const u8, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!std.json.Value {
    // Check for null
    if (isNull(content)) return .null;

    // Check for boolean
    if (boolean.parseBool(content)) |b| {
        return .{ .bool = b };
    } else |_| {}

    // Check for number - try integer first, then float
    if (number.parseInt(i64, content)) |i| {
        return .{ .integer = i };
    } else |_| {}

    if (number.parseFloat(f64, content)) |_| {
        return .{ .number_string = try ctx.allocator.dupe(u8, content) };
    } else |_| {}

    // Otherwise, it's a string
    const str = try string.parseString(content, ctx.allocator);
    return .{ .string = str };
}

/// Parse a std.json.Value from the scanner.
fn parseStdJsonValue(scanner: *Scanner, base_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, TypeMismatch, InvalidArrayLength, SyntaxError, UnexpectedEof })!std.json.Value {
    // Root form detection (§5): only applies at depth 0
    if (base_indent == 0) {
        // Check for empty document
        const first_line = scanner.peek() orelse {
            // Empty document → empty object
            return .{ .object = std.json.ObjectMap.init(ctx.allocator) };
        };

        // Check for root array header: [N]:
        if (first_line.content.len > 0 and first_line.content[0] == '[') {
            if (std.mem.indexOfScalar(u8, first_line.content, ':')) |colon_pos| {
                const before_colon = first_line.content[0..colon_pos];
                if (std.mem.indexOfScalar(u8, before_colon, ']')) |_| {
                    // This is a root array header [N]:
                    // Parse it as an inline primitive array
                    return try parseRootArrayStdJson(scanner, ctx);
                }
            }
        }

        // Check for single primitive (exactly one line, no colon)
        if (std.mem.indexOfScalar(u8, first_line.content, ':') == null) {
            // Count total non-empty lines at depth 0
            var line_count: usize = 0;
            var temp_scanner = scanner.*;
            while (temp_scanner.peek()) |peek_line| {
                if (peek_line.indent == 0) {
                    line_count += 1;
                }
                _ = temp_scanner.next();
            }

            if (line_count == 1) {
                // Single primitive
                _ = scanner.next();
                const content = std.mem.trim(u8, first_line.content, " \t");
                return try parseStdJsonSinglePrimitive(content, ctx);
            } else {
                // Multiple depth-0 lines without colons - invalid per §5
                return error.SyntaxError;
            }
        }
    }

    const line = scanner.peek() orelse return .null;

    // If this line has a colon, it's an object (key-value structure)
    if (std.mem.indexOfScalar(u8, line.content, ':')) |_| {
        return try parseStdJsonObject(scanner, base_indent, ctx);
    }

    const content = std.mem.trim(u8, line.content, " \t");

    // Check for null
    if (isNull(content)) {
        _ = scanner.next();
        return .null;
    }

    // Check for boolean
    if (boolean.parseBool(content)) |b| {
        _ = scanner.next();
        return .{ .bool = b };
    } else |_| {}

    // Check for number - try integer first, then float
    if (number.parseInt(i64, content)) |i| {
        _ = scanner.next();
        return .{ .integer = i };
    } else |_| {}

    if (number.parseFloat(f64, content)) |_| {
        _ = scanner.next();
        return .{ .number_string = try ctx.allocator.dupe(u8, content) };
    } else |_| {}

    // Otherwise, it's a string
    _ = scanner.next();
    const str = try string.parseString(content, ctx.allocator);
    return .{ .string = str };
}

/// Parse a single primitive value for std.json.Value (for root form detection)
fn parseStdJsonSinglePrimitive(content: []const u8, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!std.json.Value {
    if (isNull(content)) return .null;

    if (boolean.parseBool(content)) |b| {
        return .{ .bool = b };
    } else |_| {}

    if (number.parseInt(i64, content)) |i| {
        return .{ .integer = i };
    } else |_| {}

    if (number.parseFloat(f64, content)) |_| {
        return .{ .number_string = try ctx.allocator.dupe(u8, content) };
    } else |_| {}

    const str = try string.parseString(content, ctx.allocator);
    return .{ .string = str };
}

/// Parse a std.json.Value object
fn parseStdJsonObject(scanner: *Scanner, base_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!std.json.Value {
    var object = std.json.ObjectMap.init(ctx.allocator);
    errdefer object.deinit();

    while (scanner.peek()) |line| {
        // Stop if dedented (exited this object)
        if (line.indent < base_indent) break;

        // Skip if too indented (should have been consumed by nested parse)
        if (line.indent > base_indent) {
            _ = scanner.next();
            continue;
        }

        // Parse key-value pair at this level
        // Find colon outside quotes (important for headers with quoted field names)
        const colon_pos = findUnquotedColon(line.content) orelse {
            _ = scanner.next();
            continue;
        };

        const key_str = std.mem.trim(u8, line.content[0..colon_pos], " \t");

        // Check if this is an array header (key contains [...])
        // But ignore brackets if the entire key is quoted
        const is_quoted_key = key_str.len >= 2 and key_str[0] == '"' and key_str[key_str.len - 1] == '"';
        const has_array_header = !is_quoted_key and std.mem.indexOfScalar(u8, key_str, '[') != null;

        // Handle array keys like "friends[3]" - extract key name before bracket
        var key: []const u8 = undefined;
        if (is_quoted_key) {
            // Quoted key - parse and unescape
            key = try string.parseString(key_str, ctx.allocator);
        } else if (std.mem.indexOfScalar(u8, key_str, '[')) |bracket_pos| {
            // Array key - extract name before bracket
            key = try ctx.allocator.dupe(u8, key_str[0..bracket_pos]);
        } else {
            // Plain key
            key = try ctx.allocator.dupe(u8, key_str);
        }
        errdefer ctx.allocator.free(key);

        const value_str = std.mem.trim(u8, line.content[colon_pos + 1 ..], " \t");

        // Consume the line
        _ = scanner.next();

        // Check if value is inline or nested
        var val: std.json.Value = undefined;
        if (value_str.len > 0) {
            // If the key has an array header, parse as inline array with validation
            if (has_array_header) {
                // Parse array header from the full line to get length and delimiter
                const header = try array.parseArrayHeader(line.content, ctx.allocator);
                defer header.deinit(ctx.allocator);

                // Parse inline primitive array values
                const delim_char = header.delimiter.char();
                const parsed_values = try parseDelimitedValues(value_str, delim_char, ctx.allocator);
                defer {
                    for (parsed_values) |v| {
                        ctx.allocator.free(v);
                    }
                    ctx.allocator.free(parsed_values);
                }

                var items = std.array_list.Managed(std.json.Value).init(ctx.allocator);
                defer items.deinit();

                for (parsed_values) |v| {
                    if (v.len == 0) continue;
                    const value = try parsePrimitiveToStdJsonValue(v, ctx);
                    try items.append(value);
                }

                const count = items.items.len;

                // Verify count matches header
                if (count != header.length) {
                    return error.SyntaxError;
                }

                // Convert to array
                const owned_slice = try items.toOwnedSlice();
                const result = std.json.Array{ .items = owned_slice, .capacity = owned_slice.len, .allocator = ctx.allocator };
                val = .{ .array = result };
            } else {
                // Inline value - parse it directly (not an array)
                if (isNull(value_str)) {
                    val = .null;
                } else if (boolean.parseBool(value_str)) |b| {
                    val = .{ .bool = b };
                } else |_| {
                    if (number.parseInt(i64, value_str)) |i| {
                        val = .{ .integer = i };
                    } else |_| {
                        if (number.parseFloat(f64, value_str)) |_| {
                            val = .{ .number_string = try ctx.allocator.dupe(u8, value_str) };
                        } else |_| {
                            const str = try string.parseString(value_str, ctx.allocator);
                            val = .{ .string = str };
                        }
                    }
                }
            }
        } else {
            // Empty value - could be a nested object/array or null
            if (has_array_header) {
                // Array header with no inline values - parse as list or tabular array
                const header = try array.parseArrayHeader(line.content, ctx.allocator);
                defer header.deinit(ctx.allocator);

                // Tabular arrays - parse rows and validate field counts
                if (header.fields) |fields| {
                    var items = std.array_list.Managed(std.json.Value).init(ctx.allocator);
                    errdefer {
                        for (items.items) |*item| {
                            freeStdJsonValue(item, ctx.allocator);
                        }
                        items.deinit();
                    }

                    const row_indent = base_indent + 2;
                    var count: usize = 0;

                    while (scanner.peek()) |next_line| {
                        if (next_line.indent < row_indent) break;
                        if (next_line.indent != row_indent) {
                            _ = scanner.next();
                            continue;
                        }

                        // Parse the row using delimiter-aware splitting
                        const delim_char = header.delimiter.char();
                        const row_values = try parseDelimitedValues(next_line.content, delim_char, ctx.allocator);
                        defer {
                            for (row_values) |rv| {
                                ctx.allocator.free(rv);
                            }
                            ctx.allocator.free(row_values);
                        }

                        // Validate row width matches field count
                        if (row_values.len != fields.len) {
                            return error.SyntaxError;
                        }

                        // Create object from fields and values
                        var obj = std.json.ObjectMap.init(ctx.allocator);
                        errdefer obj.deinit();

                        for (fields, 0..) |field, fi| {
                            const field_key = try ctx.allocator.dupe(u8, field);
                            const field_value = try parsePrimitiveToStdJsonValue(row_values[fi], ctx);
                            try obj.put(field_key, field_value);
                        }

                        try items.append(.{ .object = obj });
                        _ = scanner.next();
                        count += 1;
                    }

                    // Verify count matches header
                    if (count != header.length) {
                        return error.SyntaxError;
                    }

                    const owned_slice = try items.toOwnedSlice();
                    const result = std.json.Array{ .items = owned_slice, .capacity = owned_slice.len, .allocator = ctx.allocator };
                    val = .{ .array = result };
                } else {
                    // List array - validate count
                    var items = std.array_list.Managed(std.json.Value).init(ctx.allocator);
                    defer items.deinit();

                    const item_indent = base_indent + 2;
                    var count: usize = 0;

                    while (scanner.peek()) |next_line| {
                        if (next_line.indent < item_indent) break;
                        if (next_line.indent != item_indent) {
                            _ = scanner.next();
                            continue;
                        }

                        const is_list_item = std.mem.startsWith(u8, next_line.content, "- ") or
                            std.mem.eql(u8, next_line.content, "-");

                        if (is_list_item) {
                            _ = scanner.next();
                            if (std.mem.eql(u8, next_line.content, "-")) {
                                try items.append(.{ .object = std.json.ObjectMap.init(ctx.allocator) });
                            } else {
                                const after_hyphen = next_line.content[2..];
                                const trimmed = std.mem.trim(u8, after_hyphen, &std.ascii.whitespace);
                                const value = try parsePrimitiveToStdJsonValue(trimmed, ctx);
                                try items.append(value);
                            }
                            count += 1;
                            // Don't break early - we need to count all items to detect mismatches
                        } else {
                            break;
                        }
                    }

                    if (count != header.length) {
                        return error.SyntaxError;
                    }

                    const owned_slice = try items.toOwnedSlice();
                    const result = std.json.Array{ .items = owned_slice, .capacity = owned_slice.len, .allocator = ctx.allocator };
                    val = .{ .array = result };
                }
            } else {
                // Nested value - parse recursively with increased indent
                const peek_next = scanner.peek();
                if (peek_next) |next| {
                    if (next.indent > base_indent) {
                        val = try parseStdJsonNestedValue(scanner, base_indent, ctx);
                    } else {
                        val = .null;
                    }
                } else {
                    val = .null;
                }
            }
        }

        try object.put(key, val);
    }

    return .{ .object = object };
}

/// Parse a nested value (for std.json.Value)
/// This is called when we have `key:` with empty value and need to parse nested content.
/// The nested content must be either:
/// - Key-value pairs (nested object) - has colon
/// - If it doesn't have a colon, it's an error (missing colon in key-value context)
fn parseStdJsonNestedValue(scanner: *Scanner, parent_indent: usize, ctx: *Context) (Allocator.Error || error{ InvalidEscapeSequence, SyntaxError, InvalidArrayLength })!std.json.Value {
    const line = scanner.peek() orelse return .null;
    const child_indent = line.indent;

    if (child_indent <= parent_indent) return .null;

    // If this line has a colon, it's a nested object
    if (std.mem.indexOfScalar(u8, line.content, ':')) |_| {
        return try parseStdJsonObject(scanner, child_indent, ctx);
    }

    // No colon found - this is an error (missing colon in key-value context)
    // Per spec §14.2: "Missing colon in key context" must error
    return error.SyntaxError;
}

/// Parse individual fields of type T from the given content.
pub fn parseFieldValue(comptime T: type, val: []const u8, allocator: Allocator) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => try number.parseInt(T, val),
        .float => try number.parseFloat(T, val),
        .bool => try boolean.parseBool(val),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try string.parseString(val, allocator);
            }
            return error.TypeMismatch;
        },
        .optional => |opt| blk: {
            if (isNull(val)) {
                break :blk null;
            }
            break :blk try parseFieldValue(opt.child, val, allocator);
        },
        else => error.TypeMismatch,
    };
}

/// Helper function to free a std.json.Value
fn freeStdJsonValue(value: *std.json.Value, allocator: Allocator) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| {
                freeStdJsonValue(item, allocator);
            }
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeStdJsonValue(entry.value_ptr, allocator);
            }
            obj.deinit();
        },
    }
}
