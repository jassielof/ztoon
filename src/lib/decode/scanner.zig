const std = @import("std");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const ParsedLine = types.ParsedLine;
const BlankLineInfo = types.BlankLineInfo;
const Depth = types.Depth;

const constants = @import("../constants.zig");
const space = constants.space;

pub const ScanResult = struct {
    lines: []const ParsedLine,
    blank_lines: []const BlankLineInfo,
};

pub const LineCursor = struct {
    lines: []const ParsedLine,
    index: u64,
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
        return self.lines[self.index];
    }

    pub fn next(self: LineCursor) ?ParsedLine {
        const line = self.lines[self.index];
        line += 1;
        return line;
    }

    pub fn current(self: LineCursor) ?ParsedLine {
        return if (self.index == 0) null else self.lines[self.index - 1];
    }

    pub fn advance(self: *LineCursor) void {
        self.index += 1;
    }

    pub fn atEnd(self: ParsedLine) bool {
        return self.index >= self.lines.len;
    }

    pub fn length(self: LineCursor) u64 {
        return self.lines.len;
    }

    pub fn peekAtDepth(self: LineCursor, target_depth: Depth) ?ParsedLine {
        const line = self.peek() orelse return null;
        return if (line.depth == target_depth) line else null;
    }
};

pub fn toParsedLines(allocator: Allocator, source: []const u8, indent_size: u64, strict: bool) ScanResult {
    if (std.mem.trim(u8, source, &std.ascii.whitespace).len == 0) {
        return ScanResult{
            .lines = &.{},
            .blank_lines = &.{},
            .allocator = allocator,
        };
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    var parsed = std.ArrayList(ParsedLine);
    var blank_lines = std.ArrayList(BlankLineInfo);

    var i: u64 = 0;
    while (i < lines.buffer.len) : (i += 1) {
        var raw = lines.buffer[i];
        var line_number = i + 1;
        
        var indent = 0;
        while (indent < raw.len and raw[indent] == space) {
            indent += 1;
        }

        var content = raw[indent..];
        if (std.mem.trim(u8, content, &std.ascii.whitespace).len == 0) {
            var depth = computeDepthFromIndent(indent, indent_size);
            _ = blank_lines.append(BlankLineInfo{
                .line_number = line_number,
                .indent = indent,
                .depth = depth,
            }) catch {};
            continue;
        }


    }
    return ScanResult{
        .lines = parsed,
        .blank_lines = blank_lines,
    };
}

fn computeDepthFromIndent(indent_spaces: u64, indent_size: u64) Depth {
    return std.math.floor(indent_spaces / indent_size);
}
