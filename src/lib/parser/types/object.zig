const std = @import("std");
const array = @import("array.zig");

const fieldMatches = @import("../../utils/field.zig").fieldMatches;
const value = @import("value.zig");
const Scanner = @import("../../Scanner.zig").Scanner;
const Context = @import("../Context.zig");

pub fn parseStruct(
    comptime T: type,
    scanner: *Scanner,
    base_indent: usize,
    ctx: *Context,
) !T {
    const struct_info = @typeInfo(T).@"struct";

    var result: T = undefined;
    var fields_set = std.StaticBitSet(struct_info.fields.len).initEmpty();

    // Parse each field from input
    while (scanner.peek()) |line| {
        // Stop if dedented (exited this struct)
        if (line.indent < base_indent) break;

        // Skip if too indented (should have been consumed by nested parse)
        if (line.indent > base_indent) {
            _ = scanner.next();
            continue;
        }

        // Parse "key: value" or "key[N]:" or "key:"
        const colon_idx = std.mem.indexOfScalar(u8, line.content, ':') orelse {
            return error.MissingColon;
        };

        const key_part = std.mem.trim(u8, line.content[0..colon_idx], &std.ascii.whitespace);
        const value_part = std.mem.trim(u8, line.content[colon_idx + 1 ..], &std.ascii.whitespace);

        // Check if this is an array declaration
        const is_array = std.mem.indexOfScalar(u8, key_part, '[') != null;

        if (is_array) {
            // Parse array header
            const header = try array.parseArrayHeader(key_part, ctx.allocator);
            defer header.deinit(ctx.allocator);

            // Find matching field
            var matched = false;
            inline for (struct_info.fields, 0..) |field, i| {
                if (try fieldMatches(header.key.?, field.name, ctx.allocator)) {
                    if (fields_set.isSet(i)) {
                        return error.UnknownField; // Duplicate
                    }

                    // Consume the header line
                    _ = scanner.next();

                    // Parse array based on field type
                    const field_value = try array.parseArrayField(
                        field.type,
                        header,
                        value_part,
                        scanner,
                        line.indent,
                        ctx,
                    );

                    @field(result, field.name) = field_value;
                    fields_set.set(i);
                    matched = true;
                    break;
                }
            }

            if (!matched) return error.UnknownField;
        } else {
            // Regular field
            var matched = false;
            inline for (struct_info.fields, 0..) |field, i| {
                if (try fieldMatches(key_part, field.name, ctx.allocator)) {
                    if (fields_set.isSet(i)) {
                        return error.UnknownField; // Duplicate
                    }

                    // Consume the line
                    _ = scanner.next();

                    // Value on same line vs nested
                    const field_value = if (value_part.len > 0)
                        try value.parseInlineValue(field.type, value_part, ctx)
                    else
                        try value.parseNestedValue(field.type, scanner, line.indent, ctx);

                    @field(result, field.name) = field_value;
                    fields_set.set(i);
                    matched = true;
                    break;
                }
            }

            if (!matched) return error.UnknownField;
        }
    }

    // Check all required fields were set
    inline for (struct_info.fields, 0..) |field, i| {
        if (!fields_set.isSet(i)) {
            if (field.default_value_ptr == null and @typeInfo(field.type) != .optional) {
                return error.MissingField;
            }
        }
    }

    return result;
}
