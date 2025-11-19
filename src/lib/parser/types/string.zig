const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn parseString(content: []const u8, allocator: Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupe(u8, "");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') return try parseQuotedString(trimmed[1 .. trimmed.len - 1], allocator);
    return try allocator.dupe(u8, trimmed);
}

fn parseQuotedString(content: []const u8, allocator: Allocator) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (content[1] == '\\' and i + 1 < content.len) {
            const escaped = content[i + 1];
            const char: u8 = switch (escaped) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                else => return error.InvalidEscapeSequence,
            };
            try result.append(char);
            i += 2;
        } else {
            try result.append(content[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}
