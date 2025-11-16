//! TOON decoder - parses TOON format strings into Value structures
//!
//! This module provides functionality to parse TOON format text into
//! structured Value objects. The decoder handles:
//! - Indentation-based structure parsing
//! - Multiple array formats (inline, list, tabular)
//! - Automatic delimiter detection
//! - String escaping and unquoting
//! - Type inference for primitives
//! - Error reporting with line/column information

const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;
const DecodeOptions = types.DecodeOptions;
const Delimiter = types.Delimiter;

/// Decodes a TOON format string into a Value.
///
/// This is the main entry point for decoding. It parses the input string
/// according to the TOON specification and constructs a Value tree.
///
/// The returned Value owns its memory and must be freed using `value.deinit(allocator)`.
///
/// Parameters:
/// - `allocator`: Memory allocator for value construction
/// - `input`: TOON format string to parse
/// - `options`: Parsing options (indent size, strict mode)
///
/// Returns:
/// - A Value representing the parsed TOON data
///
/// Errors:
/// - Returns parsing errors if the input is malformed
/// - Returns allocation errors if memory allocation fails
///
/// Example:
/// ```zig
/// const input = "name: Alice\nage: 30";
/// var value = try decode(allocator, input, .{});
/// defer value.deinit(allocator);
/// ```
pub fn decode(allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions) !Value {
    var parser = Parser{
        .allocator = allocator,
        .input = input,
        .pos = 0,
        .line = 1,
        .options = options,
    };

    return try parser.parseValue(0);
}

/// Internal parser state for TOON decoding.
///
/// Maintains the current position in the input, tracks line numbers for
/// error reporting, and holds configuration options.
const Parser = struct {
    /// Allocator for creating Values and strings
    allocator: std.mem.Allocator,
    /// The input TOON string being parsed
    input: []const u8,
    /// Current byte position in the input
    pos: usize,
    /// Current line number (1-indexed, for error reporting)
    line: usize,
    /// Decoding options
    options: DecodeOptions,

    /// Calculates the current line and column position in the input.
    ///
    /// Used for error reporting to provide precise location information.
    ///
    /// Returns:
    /// - Anonymous struct with `line` and `col` fields (both 1-indexed)
    fn getLineAndCol(self: *Parser) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        var i: usize = 0;
        while (i < self.pos and i < self.input.len) : (i += 1) {
            if (self.input[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    /// Prints a formatted error message with line and column information.
    ///
    /// Parameters:
    /// - `message`: Error message to display
    fn reportError(self: *Parser, comptime message: []const u8) void {
        const loc = self.getLineAndCol();
        std.debug.print("TOON Parse Error at line {d}, column {d}: {s}\n", .{ loc.line, loc.col, message });
    }

    /// Parses a value at the current position.
    ///
    /// Automatically detects the value type:
    /// - Root arrays (identifier followed by '['')
    /// - Array headers ('[length]:')
    /// - Objects (key-value pairs with ':')
    /// - Primitives (null, bool, number, string)
    ///
    /// Parameters:
    /// - `indent_level`: Expected indentation level for nested structures
    ///
    /// Returns:
    /// - Parsed Value
    fn parseValue(self: *Parser, indent_level: usize) anyerror!Value {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return Value{ .object = std.StringArrayHashMap(Value).init(self.allocator) };
        }

        // Check for root array (starts with identifier followed by '[')
        if (indent_level == 0) {
            var i = self.pos;
            while (i < self.input.len and self.input[i] != '[' and self.input[i] != ':' and self.input[i] != '\n') {
                i += 1;
            }
            if (i < self.input.len and self.input[i] == '[') {
                // This is a root array
                return try self.parseRootArray();
            }
        }

        // Check for array header
        if (self.peekArrayHeader()) {
            return try self.parseArray(indent_level, null);
        }

        // Check for object (key: value)
        if (try self.peekObjectKey()) {
            return try self.parseObject(indent_level);
        }

        // Parse as primitive
        return try self.parsePrimitive();
    }

    fn parseRootArray(self: *Parser) anyerror!Value {
        // Skip key (if present) - just move to '['
        while (self.pos < self.input.len and self.input[self.pos] != '[') {
            self.pos += 1;
        }

        return try self.parseArray(0, null);
    }

    /// Parses an object (collection of key-value pairs).
    ///
    /// Objects are parsed as indented key-value pairs, where each line at
    /// the current indent level represents an entry. Nested objects and
    /// arrays are handled recursively.
    ///
    /// Parameters:
    /// - `indent_level`: Expected indentation level for object entries
    ///
    /// Returns:
    /// - Value containing the parsed object
    fn parseObject(self: *Parser, indent_level: usize) anyerror!Value {
        var obj = std.StringArrayHashMap(Value).init(self.allocator);
        errdefer {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            obj.deinit();
        }

        while (self.pos < self.input.len) {
            // For nested objects, check if we're at the expected indent level
            if (indent_level > 0) {
                const current_indent = self.getCurrentIndent();
                if (current_indent < indent_level) break;
                if (current_indent > indent_level) break;
                // Skip the indent spaces
                self.pos += indent_level * self.options.indent;
            } else {
                self.skipWhitespace();
                if (self.pos >= self.input.len) break;
            }

            // Parse key
            const key = try self.parseKey();

            // Expect colon
            self.skipSpaces();
            if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                self.reportError("Expected ':' after key");
                self.allocator.free(key);
                return error.ExpectedColon;
            }
            self.pos += 1;

            // Check for array
            self.skipSpaces();
            if (self.pos < self.input.len and self.input[self.pos] == '[') {
                const value = self.parseArray(indent_level + 1, key) catch |err| {
                    self.allocator.free(key);
                    return err;
                };
                try obj.put(key, value);
            } else {
                self.skipSpaces();

                // Check if next line is indented (nested object)
                if (self.pos >= self.input.len or self.input[self.pos] == '\n') {
                    if (self.pos < self.input.len) self.pos += 1; // Skip newline
                    const next_indent = self.getCurrentIndent();
                    if (next_indent > indent_level) {
                        const value = self.parseObject(next_indent) catch |err| {
                            self.allocator.free(key);
                            return err;
                        };
                        try obj.put(key, value);
                        // Don't skip to next line - parseObject already consumed everything
                        continue;
                    } else {
                        // Empty object
                        try obj.put(key, Value{ .object = std.StringArrayHashMap(Value).init(self.allocator) });
                    }
                } else {
                    const value = self.parsePrimitive() catch |err| {
                        self.allocator.free(key);
                        return err;
                    };
                    try obj.put(key, value);
                }
            }

            self.skipToNextLine();
        }

        return Value{ .object = obj };
    }

    /// Parses an array from its header and content.
    ///
    /// Handles three array formats:
    /// 1. Tabular arrays with field headers: `[3]{name,age}: ...`
    /// 2. Inline arrays: `[3]: value1, value2, value3`
    /// 3. List arrays: `[3]: \n - item1 \n - item2 \n - item3`
    ///
    /// The delimiter is automatically detected from the content or header.
    ///
    /// Parameters:
    /// - `indent_level`: Current indentation level
    /// - `key`: Optional key name (currently unused but reserved for future use)
    ///
    /// Returns:
    /// - Value containing the parsed array
    fn parseArray(self: *Parser, indent_level: usize, key: ?[]const u8) anyerror!Value {
        _ = key;
        _ = indent_level;

        // Parse array header: [length]:
        if (self.input[self.pos] != '[') {
            self.reportError("Expected '[' to start array header");
            return error.ExpectedArrayHeader;
        }
        self.pos += 1;

        // Parse length
        const len_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
            self.pos += 1;
        }
        const length = try std.fmt.parseInt(usize, self.input[len_start..self.pos], 10);

        // Check for delimiter marker after length
        var delimiter = Delimiter.comma;
        if (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\t') {
                delimiter = .tab;
                self.pos += 1;
            } else if (c == '|') {
                delimiter = .pipe;
                self.pos += 1;
            } else if (c == ',') {
                delimiter = .comma;
                self.pos += 1;
            }
        }

        if (self.pos >= self.input.len or self.input[self.pos] != ']') {
            self.reportError("Expected ']' to close array header");
            return error.ExpectedClosingBracket;
        }
        self.pos += 1;

        // Check for tabular field list {field1,field2,...}:
        var field_list: ?[][]const u8 = null;

        if (self.pos < self.input.len and self.input[self.pos] == '{') {
            self.pos += 1; // skip '{'

            // Delimiter is already set from array header or default
            // If not set explicitly in header, detect from field list
            if (delimiter == .comma) {
                const field_start = self.pos;
                const field_end = blk: {
                    var i = self.pos;
                    while (i < self.input.len and self.input[i] != '}') : (i += 1) {}
                    break :blk i;
                };

                const field_content = self.input[field_start..field_end];
                if (std.mem.indexOf(u8, field_content, "\t")) |_| {
                    delimiter = .tab;
                } else if (std.mem.indexOf(u8, field_content, "|")) |_| {
                    delimiter = .pipe;
                }
            }

            // Parse field names
            var fields = std.ArrayList([]const u8){};
            errdefer {
                for (fields.items) |field| {
                    self.allocator.free(field);
                }
                fields.deinit(self.allocator);
            }

            while (self.pos < self.input.len and self.input[self.pos] != '}') {
                self.skipSpaces();
                const field_name = try self.parseFieldName(delimiter);
                try fields.append(self.allocator, field_name);

                self.skipSpaces();
                if (self.pos < self.input.len and self.input[self.pos] == delimiter.toChar()) {
                    self.pos += 1; // skip delimiter
                }
            }

            if (self.pos >= self.input.len or self.input[self.pos] != '}') {
                return error.ExpectedClosingBrace;
            }
            self.pos += 1; // skip '}'

            field_list = try fields.toOwnedSlice(self.allocator);
        }
        defer if (field_list) |fl| {
            // Free field names and the array
            for (fl) |field| {
                self.allocator.free(field);
            }
            self.allocator.free(fl);
        };

        if (self.pos >= self.input.len or self.input[self.pos] != ':') {
            self.reportError("Expected ':' after array header");
            return error.ExpectedColon;
        }
        self.pos += 1;

        var items = try self.allocator.alloc(Value, length);
        errdefer {
            for (items[0..length]) |*item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items);
        }

        if (length == 0) {
            return Value{ .array = items };
        }

        self.skipSpaces();

        // Handle tabular rows if field_list is present
        if (field_list) |fields| {
            for (items) |*item| {
                self.skipToNextLine();
                self.skipSpaces();

                // Parse row as delimiter-separated values
                var obj = std.StringArrayHashMap(Value).init(self.allocator);
                errdefer obj.deinit();

                for (fields, 0..) |field, i| {
                    self.skipSpaces();
                    const value = try self.parsePrimitive();
                    // Duplicate the field name for this object
                    const field_copy = try self.allocator.dupe(u8, field);
                    try obj.put(field_copy, value);

                    if (i < fields.len - 1) {
                        self.skipSpaces();
                        if (self.pos < self.input.len and self.input[self.pos] == delimiter.toChar()) {
                            self.pos += 1;
                        }
                    }
                }

                item.* = Value{ .object = obj };
            }
            return Value{ .array = items };
        }

        // Check if inline (same line) or multi-line
        if (self.pos < self.input.len and self.input[self.pos] != '\n') {
            // Inline array - detect delimiter
            const rest = self.input[self.pos..];
            if (std.mem.indexOf(u8, rest, "\t") != null) {
                delimiter = .tab;
            } else if (std.mem.indexOf(u8, rest, "|") != null) {
                delimiter = .pipe;
            }

            for (items, 0..) |*item, i| {
                self.skipSpaces();
                item.* = try self.parsePrimitive();

                if (i < length - 1) {
                    self.skipSpaces();
                    if (self.pos < self.input.len and self.input[self.pos] == delimiter.toChar()) {
                        self.pos += 1;
                    }
                }
            }
        } else {
            // Multi-line array with list items
            for (items) |*item| {
                self.skipToNextLine();
                const current_indent = self.getCurrentIndent();

                // Expect list marker
                self.skipSpaces();
                if (self.pos >= self.input.len or self.input[self.pos] != '-') {
                    return error.ExpectedListMarker;
                }
                self.pos += 1;
                self.skipSpaces();

                item.* = try self.parseValue(current_indent);
            }
        }

        return Value{ .array = items };
    }

    /// Parses a primitive value (null, boolean, number, or string).
    ///
    /// Type detection order:
    /// 1. Quoted strings (start with '"')
    /// 2. null literal
    /// 3. Boolean literals (true/false)
    /// 4. Numeric values (integers and floats)
    /// 5. Unquoted strings (fallback)
    ///
    /// Returns:
    /// - Value containing the parsed primitive
    fn parsePrimitive(self: *Parser) anyerror!Value {
        self.skipSpaces();

        if (self.pos >= self.input.len) {
            return Value{ .null = {} };
        }

        // String (quoted or unquoted)
        if (self.input[self.pos] == '"') {
            return try self.parseQuotedString();
        }

        // Find end of token
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\n' or c == '\r' or c == ',' or c == '\t' or c == '|' or c == ' ') {
                break;
            }
            self.pos += 1;
        }

        const token = self.input[start..self.pos];

        // null
        if (std.mem.eql(u8, token, "null")) {
            return Value{ .null = {} };
        }

        // boolean
        if (std.mem.eql(u8, token, "true")) {
            return Value{ .bool = true };
        }
        if (std.mem.eql(u8, token, "false")) {
            return Value{ .bool = false };
        }

        // number
        if (std.fmt.parseFloat(f64, token)) |num| {
            return Value{ .number = num };
        } else |_| {
            // unquoted string
            const str = try self.allocator.dupe(u8, token);
            return Value{ .string = str };
        }
    }

    /// Parses a quoted string with escape sequence processing.
    ///
    /// Handles standard escape sequences:
    /// - \n: newline
    /// - \r: carriage return
    /// - \t: tab
    /// - \\: backslash
    /// - \": quote
    ///
    /// Returns:
    /// - Value containing the unescaped string
    fn parseQuotedString(self: *Parser) anyerror!Value {
        if (self.input[self.pos] != '"') {
            self.reportError("Expected '\"' to start quoted string");
            return error.ExpectedQuote;
        }
        self.pos += 1;

        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == '"') {
                self.pos += 1;
                return Value{ .string = try result.toOwnedSlice(self.allocator) };
            }

            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return error.UnexpectedEOF;

                const escaped = self.input[self.pos];
                switch (escaped) {
                    'n' => try result.append(self.allocator, '\n'),
                    'r' => try result.append(self.allocator, '\r'),
                    't' => try result.append(self.allocator, '\t'),
                    '\\' => try result.append(self.allocator, '\\'),
                    '"' => try result.append(self.allocator, '"'),
                    else => {
                        try result.append(self.allocator, '\\');
                        try result.append(self.allocator, escaped);
                    },
                }
                self.pos += 1;
            } else {
                try result.append(self.allocator, c);
                self.pos += 1;
            }
        }

        self.reportError("Unterminated string: missing closing quote");
        return error.UnterminatedString;
    }

    /// Parses an object key (quoted or unquoted identifier).
    ///
    /// Keys are terminated by ':', '[', space, or newline.
    ///
    /// Returns:
    /// - Owned string containing the key name
    fn parseKey(self: *Parser) anyerror![]const u8 {
        self.skipSpaces();

        if (self.pos >= self.input.len) return error.UnexpectedEOF;

        if (self.input[self.pos] == '"') {
            const val = try self.parseQuotedString();
            return val.string;
        }

        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ':' or c == ' ' or c == '\n' or c == '[') break;
            self.pos += 1;
        }

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    /// Parses a field name from a tabular array header.
    ///
    /// Similar to parseKey but uses the array's delimiter for termination.
    ///
    /// Parameters:
    /// - `delimiter`: The delimiter character for this array
    ///
    /// Returns:
    /// - Owned string containing the field name
    fn parseFieldName(self: *Parser, delimiter: Delimiter) anyerror![]const u8 {
        self.skipSpaces();

        if (self.pos >= self.input.len) return error.UnexpectedEOF;

        if (self.input[self.pos] == '"') {
            const val = try self.parseQuotedString();
            return val.string;
        }

        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '}' or c == delimiter.toChar() or c == ' ' or c == '\n') break;
            self.pos += 1;
        }

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    /// Checks if an array header '[' appears at the current position.
    ///
    /// Returns:
    /// - `true` if '[' is found after skipping spaces
    fn peekArrayHeader(self: *Parser) bool {
        var i = self.pos;
        while (i < self.input.len and self.input[i] == ' ') i += 1;
        return i < self.input.len and self.input[i] == '[';
    }

    /// Checks if the current line contains an object key (has a ':').
    ///
    /// Returns:
    /// - `true` if ':' appears before newline on current line
    fn peekObjectKey(self: *Parser) anyerror!bool {
        var i = self.pos;
        while (i < self.input.len) {
            const c = self.input[i];
            if (c == ':') return true;
            if (c == '\n') return false;
            i += 1;
        }
        return false;
    }

    /// Gets the current indentation level (in multiples of indent size).
    ///
    /// Returns:
    /// - Number of indent units at current position
    fn getCurrentIndent(self: *Parser) usize {
        var indent: usize = 0;
        var i = self.pos;
        while (i < self.input.len and self.input[i] == ' ') {
            indent += 1;
            i += 1;
        }
        return indent / self.options.indent;
    }

    /// Skips all whitespace characters (spaces, newlines, carriage returns).
    ///
    /// Updates line counter when newlines are encountered.
    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\n' or c == '\r') {
                if (c == '\n') self.line += 1;
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    /// Skips space characters only (not newlines).
    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] == ' ') {
            self.pos += 1;
        }
    }

    /// Advances position to the start of the next line.
    ///
    /// Updates line counter when newline is found.
    fn skipToNextLine(self: *Parser) void {
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.pos += 1;
                self.line += 1;
                break;
            }
            self.pos += 1;
        }
    }
};
