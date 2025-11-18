const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../errors.zig");

const Allocator = std.mem.Allocator;
const ParsedLine = types.ParsedLine;
const BlankLineInfo = types.BlankLineInfo;
const Depth = types.Depth;

const constants = @import("../constants.zig");
const space = constants.space;
const tab = constants.tab;

/// Result of scanning and parsing lines from TOON source
pub const ScanResult = struct {
    lines: []const ParsedLine,
    blank_lines: []const BlankLineInfo,
    allocator: Allocator,

    /// Free allocated memory
    pub fn deinit(self: *ScanResult) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.blank_lines);
    }
};

/// Cursor for iterating through parsed lines
pub const LineCursor = struct {
    lines: []const ParsedLine,
    index: usize,
    blank_lines: []const BlankLineInfo,

    pub fn init(
        lines: []const ParsedLine,
        blank_lines: []const BlankLineInfo,
    ) LineCursor {
        return .{
            .lines = lines,
            .index = 0,
            .blank_lines = blank_lines,
        };
    }

    pub fn getBlankLines(self: LineCursor) []const BlankLineInfo {
        return self.blank_lines;
    }

    pub fn peek(self: LineCursor) ?ParsedLine {
        if (self.index >= self.lines.len) return null;
        return self.lines[self.index];
    }

    pub fn next(self: *LineCursor) ?ParsedLine {
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        return line;
    }

    pub fn current(self: LineCursor) ?ParsedLine {
        return if (self.index == 0) null else self.lines[self.index - 1];
    }

    pub fn advance(self: *LineCursor) void {
        self.index += 1;
    }

    pub fn atEnd(self: LineCursor) bool {
        return self.index >= self.lines.len;
    }

    pub fn getLength(self: LineCursor) usize {
        return self.lines.len;
    }

    pub fn peekAtDepth(self: LineCursor, target_depth: Depth) ?ParsedLine {
        const line = self.peek() orelse return null;
        return if (line.depth == target_depth) line else null;
    }
};

/// Parses source text into structured lines and blank line information
pub fn toParsedLines(allocator: Allocator, source: []const u8, indent_size: u64, strict: bool) !ScanResult {
    // Handle empty source
    if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) {
        const empty_lines = try allocator.alloc(ParsedLine, 0);
        const empty_blanks = try allocator.alloc(BlankLineInfo, 0);
        return ScanResult{
            .lines = empty_lines,
            .blank_lines = empty_blanks,
            .allocator = allocator,
        };
    }

    var parsed = std.ArrayList(ParsedLine){};
    errdefer parsed.deinit(allocator);

    var blank_lines = std.ArrayList(BlankLineInfo){};
    errdefer blank_lines.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u64 = 1;

    while (lines.next()) |raw| {
        // Count leading spaces for indentation
        var indent: u64 = 0;
        while (indent < raw.len and raw[indent] == space) : (indent += 1) {}

        // Extract content after indentation
        const content = raw[indent..];

        // Check if line is blank (only whitespace)
        if (std.mem.trim(u8, content, &std.ascii.whitespace).len == 0) {
            const depth = computeDepthFromIndent(indent, indent_size);
            try blank_lines.append(allocator, BlankLineInfo{
                .line_number = line_number,
                .indent = indent,
                .depth = depth,
            });
            line_number += 1;
            continue;
        }

        const depth = computeDepthFromIndent(indent, indent_size);

        // Strict mode validations
        if (strict) {
            // Find the full leading whitespace region (spaces and tabs)
            var whitespace_end: usize = 0;
            while (whitespace_end < raw.len and
                (raw[whitespace_end] == space or raw[whitespace_end] == tab)) : (whitespace_end += 1)
            {}

            // Check for tabs in leading whitespace
            if (std.mem.indexOfScalar(u8, raw[0..whitespace_end], tab) != null) {
                return errors.ScanError.TabsNotAllowedInStrictMode;
            }

            // Check for exact multiples of indentSize
            if (indent > 0 and indent % indent_size != 0) {
                return errors.ScanError.InvalidIndentation;
            }
        }

        // Add parsed line
        try parsed.append(allocator, ParsedLine{
            .raw = raw,
            .indent = indent,
            .content = content,
            .depth = depth,
            .line_number = line_number,
        });

        line_number += 1;
    }

    return ScanResult{
        .lines = try parsed.toOwnedSlice(allocator),
        .blank_lines = try blank_lines.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Computes nesting depth from indentation spaces
fn computeDepthFromIndent(indent_spaces: u64, indent_size: u64) Depth {
    return @divFloor(indent_spaces, indent_size);
}
