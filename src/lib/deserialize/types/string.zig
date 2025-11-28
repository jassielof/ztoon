const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn parseString(content: []const u8, allocator: Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupe(u8, "");

    // Check if this is a quoted string
    if (trimmed[0] == '"') {
        // Find the closing quote, accounting for escape sequences
        const closing = findClosingQuote(trimmed);
        if (closing == null) {
            // No closing quote found - unterminated string
            return error.SyntaxError;
        }

        // Closing quote must be at the end
        if (closing.? != trimmed.len - 1) {
            return error.SyntaxError;
        }

        // Parse the quoted content (between the quotes)
        return try parseQuotedString(trimmed[1..closing.?], allocator);
    }

    // Unquoted string
    return try allocator.dupe(u8, trimmed);
}

/// Find the closing quote in a quoted string, accounting for escape sequences.
/// Returns the index of the closing quote, or null if not found.
fn findClosingQuote(content: []const u8) ?usize {
    if (content.len < 2 or content[0] != '"') return null;

    var i: usize = 1;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            // Skip escape sequence
            i += 2;
            continue;
        }
        if (content[i] == '"') {
            return i;
        }
        i += 1;
    }
    return null;
}

fn parseQuotedString(content: []const u8, allocator: Allocator) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
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
