const std = @import("std");

pub const Scanner = @This();

const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const BitStack = std.BitStack;

lines: []Line,
current_index: usize,
allocator: Allocator,

pub const Line = struct {
    content: []const u8,
    indent: usize,
    number: usize,
};
pub fn init(allocator: Allocator, source: []const u8, expected_indent: usize) !Scanner {
    _ = expected_indent;
    var line_list = std.array_list.Managed(Line).init(allocator);
    errdefer line_list.deinit();

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 1;
    while (line_iter.next()) |raw_line| : (line_number += 1) {
        if (raw_line.len == 0) continue;

        const trimmed_end = std.mem.trimRight(u8, raw_line, &std.ascii.whitespace);
        if (trimmed_end.len == 0) continue;

        const first_non_space = std.mem.indexOfNone(u8, trimmed_end, " \t") orelse continue;
        if (trimmed_end[first_non_space] == '#') continue;

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
    };
}
pub fn deinit(self: *Scanner) void {
    self.allocator.free(self.lines);
}
pub fn peek(self: *const Scanner) ?Line {
    if (self.current_index >= self.lines.len) return null;
    return self.lines[self.current_index];
}
pub fn next(self: *Scanner) ?Line {
    const line = self.peek() orelse return null;
    self.current_index += 1;
    return line;
}
pub fn hasMore(self: *const Scanner) bool {
    return self.current_index < self.lines.len;
}
pub fn peekAhead(self: *const Scanner, n: usize) ?Line {
    const index = self.current_index + n;
    if (index >= self.lines.len) return null;
    return self.lines[index];
}
pub fn position(self: *const Scanner) usize {
    return self.current_index;
}

pub fn setPosition(self: *Scanner, pos: usize) !void {
    self.current_index = pos;
}
fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else break;
    }
    return count;
}
