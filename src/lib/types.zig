const std = @import("std");
const constants = @import("constants.zig");

pub const JsonPrimitive = union(enum) { string: []const u8, number: f64, boolean: bool, null: void };
pub const JsonObject = std.StringArrayHashMap(JsonValue);
pub const JsonArray = std.ArrayList(JsonValue);
pub const JsonValue = union(enum) {
    primitive: JsonPrimitive,
    object: JsonObject,
    array: JsonArray,
};

/// Options for encoding TOON data.
pub const EncodingOptions = struct {
    /// Number of spaces per indentation level.
    indent: ?u64 = 2,
    /// Delimiter to use for tabular array rows and inline primitive arrays.
    delimiter: ?constants.Delimiter = constants.Delimiters.comma,
    /// Whether to enable key folding to collapse single-key wrapper chains.
    /// When set to 'safe', nested objects with single keys are collapsed into dotted paths (e.g., data.metadata.items instead of nested indentation).
    key_folding: enum { off, safe } = .off,
    /// Maximum number of segmest to fold when key folding is enabled.
    /// Controls how deep the folding can go in single-key chains.
    /// Values 0 or 1 have no practical effect (treated as effectively disabled).
    flatten_depth: ?u64 = null,
};

pub const ResolvedEncodingOptions = struct {
    indent: u64,
    delimiter: constants.Delimiter,
    key_folding: enum { off, safe },
    flatten_depth: ?u64,
};

pub const ExpandPathsMode = enum { off, safe };

/// Options for decoding TOON data.
pub const DecodingOptions = struct {
    /// Number of spaces per indentation level.
    indent: ?u64 = 2,
    /// Whether to enforce strict validation of array lengths and tabular row counts.
    strict: bool = true,
    /// Whether to enable path expansion to reconstruct dotted keys into nested objects.
    /// When set to 'safe', keys containing dots are expanded into nested structures if all segments are valid identifiers (e.g., data.metadata.items becomes nested objects).
    /// Pairs with key folding set to 'safe' for lossless round-trips.
    expand_paths: ExpandPathsMode = .off,
};

pub const ResolvedDecodingOptions = struct {
    indent: u64,
    strict: bool,
    expand_paths: ExpandPathsMode,
};

pub const ArrayHeaderInfo = struct { key: ?[]const u8, length: u64, delimiter: constants.Delimiter, fields: ?[]const []const u8 };

pub const ParsedLine = struct { raw: []const u8, depth: Depth, indent: u64, content: []const u8, line_number: u64 };

pub const BlankLineInfo = struct {
    line_number: u64,
    indent: u64,
    depth: Depth,
};

pub const Depth = u64;
