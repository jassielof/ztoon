const std = @import("std");
const types = @import("types.zig");
const constants = @import("constants.zig");
const decode_scanner = @import("decode/scanner.zig");
const decode_decoders = @import("decode/decoders.zig");
const decode_expand = @import("decode/expand.zig");

const Allocator = std.mem.Allocator;

// Export types for external use (e.g., tests)
pub const DecodingOptions = types.DecodingOptions;
pub const EncodingOptions = types.EncodingOptions;
pub const JsonValue = types.JsonValue;
pub const JsonObject = types.JsonObject;
pub const JsonArray = types.JsonArray;
pub const JsonPrimitive = types.JsonPrimitive;
// pub fn encode(allocator: std.mem.Allocator, input: types.JsonValue, options: ?types.EncodingOptions) ![]const u8 {
//     var normalizedValue = normalizeValue(input);
//     var resolvedOptions = resolveEncodingOptions(options);

//     return encodeValue();
// }

pub fn decode(allocator: Allocator, input: []const u8, options: ?types.DecodingOptions) !types.JsonValue {
    const resolved_options = resolveDecodingOptions(options);

    // Scan the input into parsed lines
    var scanning_result = try decode_scanner.toParsedLines(allocator, input, resolved_options.indent, resolved_options.strict);
    defer scanning_result.deinit();

    if (scanning_result.lines.len == 0) {
        const empty_obj = types.JsonObject.init(allocator);
        return types.JsonValue{ .object = empty_obj };
    }

    // Create cursor for iteration
    var cursor = decode_scanner.LineCursor.init(scanning_result.lines, scanning_result.blank_lines);

    // Decode the value
    const decoded_value = try decode_decoders.decodeValueFromLines(allocator, &cursor, resolved_options);

    // Expand paths if requested
    if (resolved_options.expand_paths == .safe) {
        return try decode_expand.expandPathsSafe(allocator, decoded_value, null, resolved_options.strict);
    }

    return decoded_value;
}

// fn resolveEncodingOptions(options: ?types.EncodingOptions) !types.ResolvedEncodingOptions {
//     if (options) |opts| {
//         return .{
//             .indent = opts.indent orelse 2,
//             .delimiter = opts.delimiter orelse constants.default_delimiter,
//             .key_folding = opts.key_folding orelse .off,
//             .flatten_depth = opts.flatten_depth orelse null,
//         };
//     }

//     return .{
//         .indent = 2,
//         .delimiter = constants.default_delimiter,
//         .key_folding = .off,
//         .flatten_depth = null,
//     };
// }

fn resolveDecodingOptions(options: ?types.DecodingOptions) types.ResolvedDecodingOptions {
    if (options) |opts| {
        return .{
            .indent = opts.indent orelse 2,
            .strict = opts.strict,
            .expand_paths = opts.expand_paths,
        };
    }

    return .{
        .indent = 2,
        .strict = true,
        .expand_paths = .off,
    };
}
