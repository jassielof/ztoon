const Options = @This();

/// Number of spaces to use for indentation.
indent: usize = 2,

/// Whether to enforce strict validation for array lengths and tabular row counts.
strict: ?bool = true,
/// Whether to enable path expansion to reconstruct dotted keys into nested objects.
///
/// When set to safe, keys containing dots are expanded into nested structures if all segments are valid identifiers, for example: `data.metadata.items` turns into nested objects.
///
/// It pairs with key folding set to safe for lossless round-trips.
expand_paths: enum { off, safe } = .off,

max_depth: usize = 256,
