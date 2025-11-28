//! A simple line-based scanner for parsing TOON files.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @This();

lines: []Line,
current_index: usize,
allocator: Allocator,
/// Line numbers of blank lines (for strict mode validation)
blank_lines: []usize,
/// Line numbers where tabs were used in indentation (for strict mode)
tab_indent_lines: []usize,

/// A single line in the TOON input
pub const Line = struct {
    content: []const u8,
    indent: usize,
    number: usize,
};

/// Initialize a scanner from a source input
pub fn init(allocator: Allocator, source: []const u8, expected_indent: usize) !Scanner {
    _ = expected_indent;
    var line_list = std.array_list.Managed(Line).init(allocator);
    errdefer line_list.deinit();

    var blank_line_list = std.array_list.Managed(usize).init(allocator);
    errdefer blank_line_list.deinit();

    var tab_indent_list = std.array_list.Managed(usize).init(allocator);
    errdefer tab_indent_list.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 1;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        // Empty line (completely blank)
        if (raw_line.len == 0) {
            try blank_line_list.append(line_number);
            continue;
        }

        const trimmed_end = std.mem.trimRight(u8, raw_line, &std.ascii.whitespace);

        // Line with only whitespace (also blank)
        if (trimmed_end.len == 0) {
            try blank_line_list.append(line_number);
            continue;
        }

        const first_non_space = std.mem.indexOfNone(u8, trimmed_end, " \t") orelse {
            try blank_line_list.append(line_number);
            continue;
        };

        // Comment line
        if (trimmed_end[first_non_space] == '#') continue;

        // Check for tabs in indentation (before first non-space character)
        const indent_part = trimmed_end[0..first_non_space];
        if (std.mem.indexOfScalar(u8, indent_part, '\t') != null) {
            try tab_indent_list.append(line_number);
        }

        const indent = countLeadingSpaces(trimmed_end);
        const contennt = trimmed_end[indent..];

        try line_list.append(Line{
            .content = contennt,
            .indent = indent,
            .number = line_number,
        });
    }

    return Scanner{
        .lines = try line_list.toOwnedSlice(),
        .current_index = 0,
        .allocator = allocator,
        .blank_lines = try blank_line_list.toOwnedSlice(),
        .tab_indent_lines = try tab_indent_list.toOwnedSlice(),
    };
}

/// Deinitialize the scanner and free resources
pub fn deinit(self: *Scanner) void {
    self.allocator.free(self.lines);
    self.allocator.free(self.blank_lines);
    self.allocator.free(self.tab_indent_lines);
}

/// Check if there are any blank lines between two line numbers (exclusive)
pub fn hasBlankLinesBetween(self: *const Scanner, start_line: usize, end_line: usize) bool {
    for (self.blank_lines) |blank_line| {
        if (blank_line > start_line and blank_line < end_line) {
            return true;
        }
    }
    return false;
}

/// Check if any lines have tabs in indentation
pub fn hasTabIndentation(self: *const Scanner) bool {
    return self.tab_indent_lines.len > 0;
}

/// Peek at the current line without consuming it
pub fn peek(self: *const Scanner) ?Line {
    if (self.current_index >= self.lines.len) return null;
    return self.lines[self.current_index];
}

/// Consume and return the current line
pub fn next(self: *Scanner) ?Line {
    const line = self.peek() orelse return null;
    self.current_index += 1;
    return line;
}

/// Check if there are more lines to read
pub fn hasMore(self: *const Scanner) bool {
    return self.current_index < self.lines.len;
}

/// Peek ahead n lines without consuming them
pub fn peekAhead(self: *const Scanner, n: usize) ?Line {
    const index = self.current_index + n;
    if (index >= self.lines.len) return null;
    return self.lines[index];
}

/// Get the current position in the scanner
pub fn position(self: *const Scanner) usize {
    return self.current_index;
}

/// Set the current position in the scanner
pub fn setPosition(self: *Scanner, pos: usize) !void {
    self.current_index = pos;
}

/// Count leading spaces in a line
fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else break;
    }
    return count;
}
