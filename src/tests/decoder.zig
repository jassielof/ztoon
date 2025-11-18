const std = @import("std");
const ztoon = @import("ztoon");
const test_types = @import("types.zig");
const testing = std.testing;

const fixtures_path = "spec/tests/fixtures/decode/";
const fixtures = [_][]const u8{
    "primitives.json",
    // "numbers.json",
    // "objects.json",
    // "arrays-primitive.json",
    // "arrays-tabular.json",
    // "arrays-nested.json",
    // "path-expansion.json",
    // "delimiters.json",
    // "whitespace.json",
    // "root-form.json",
    // "validation-errors.json",
    // "indentation-errors.json",
    // "blank-lines.json",
};

