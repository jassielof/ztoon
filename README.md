# TOONZ

A Zig implementation of the TOON (Token-Oriented Object Notation) format - a compact, human-readable encoding of the JSON data model designed for LLM input efficiency.

**[Official Specification (v3.0)](https://github.com/toon-format/spec/blob/main/SPEC.md)** | **[Format Overview](https://toonformat.dev/guide/format-overview)**

## About TOON

TOON combines YAML's indentation-based structure with CSV-style tabular arrays to achieve significant token reduction while maintaining lossless JSON compatibility. It's particularly efficient for uniform arrays of objects, achieving ~40% fewer tokens than JSON in mixed-structure benchmarks while improving LLM accuracy.

See the [official TypeScript implementation](js/) and the [full specification](spec/) for complete format details.

## Features

### Core Functionality ✅

- **Encoding/Decoding**: Full JSON ↔ TOON ↔ ZON conversion
  - `std.json.Value` ↔ TOON string serialization
  - Parse TOON to `std.json.Value` or custom Zig types
  - ZON (Zig Object Notation) support for native Zig integration

- **Data Types**: Complete JSON data model support
  - Primitives: strings, numbers, booleans, null
  - Smart string quoting (only when necessary per spec)
  - Objects: Indentation-based structure (no braces)
  - Arrays: Inline format for primitives, multi-line for objects

- **Tabular Arrays**: Optimized encoding for uniform object arrays
  - Format: `[N]{field1,field2,...}:` header with row data
  - Automatic tabular eligibility detection
  - Configurable delimiters: comma `,` (default), tab `\t`, pipe `|`
  - Delimiter auto-detection from array headers `[N,]` / `[N\t]` / `[N|]`

### Advanced Features ✅

- **Key Folding** (`key_folding = .safe`):
  - Collapse single-key wrapper chains into dotted notation
  - Example: `data.metadata.items` instead of nested indentation
  - Configurable depth limit via `flatten_depth` option

- **Path Expansion** (`expand_paths = .safe`):
  - Reconstruct dotted keys into nested objects on decode
  - Pairs with key folding for lossless round-trips
  - Example: `data.items` → `{ "data": { "items": ... } }`

- **Strict Mode Validation** (`strict = true`):
  - Array length validation against declared `[N]` counts
  - Tabular row count verification
  - Field count consistency checking
  - Malformed header detection

- **Error Handling**:
  - Comprehensive error messages with line/column information
  - Stack overflow protection via `max_depth` limits (default: 256)
  - Detailed diagnostics for debugging

### CLI Tool ✅

Smart command-line interface with automatic format detection:

```bash
# Auto-detect based on file extension
toonz input.json              # → TOON output
toonz data.toon               # → JSON output
toonz config.zon              # → TOON output

# Explicit commands
toonz serialize input.json    # JSON/ZON → TOON
toonz deserialize data.toon   # TOON → JSON

# Output format control
toonz data.toon --json        # → JSON
toonz data.toon --zon         # → ZON (Zig Object Notation)
toonz input.json --toon       # → TOON

# File I/O
toonz input.json -o output.toon
echo '{"key":"value"}' | toonz serialize

# Format command (coming soon)
toonz format data.toon        # Reformat TOON file
```

**Supported modes:**
- File extension detection (`.json`, `.toon`, `.zon`)
- Stdin/stdout streaming with pipes
- Manual command specification (`serialize`, `deserialize`, `format`)
- Output format override flags (`--json`, `--zon`, `--toon`)

## Installation & Usage

### Building from Source

```bash
# Clone the repository
git clone --recursive https://github.com/jassielof/toonz
cd toonz

# Build
zig build

# Run tests
zig build test

# Install
zig build install
```

### Library Usage

```zig
const std = @import("std");
const toonz = @import("toonz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Encode: JSON → TOON
    const json_string =
        \\{
        \\  "users": [
        \\    {"id": 1, "name": "Alice", "active": true},
        \\    {"id": 2, "name": "Bob", "active": false}
        \\  ]
        \\}
    ;

    const json_value = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_string,
        .{}
    );
    defer json_value.deinit();

    const toon_output = try toonz.serialize.stringify(
        json_value.value,
        .{ .delimiter = ',' },  // Options: delimiter, key_folding, etc.
        allocator
    );
    defer allocator.free(toon_output);

    std.debug.print("{s}\n", .{toon_output});
    // Output:
    // users[2]{id,name,active}:
    //   1,Alice,true
    //   2,Bob,false

    // Decode: TOON → JSON
    const toon_input =
        \\users[2]{id,name,active}:
        \\  1,Alice,true
        \\  2,Bob,false
    ;

    const parsed = try toonz.Parse(std.json.Value).parse(
        allocator,
        toon_input,
        .{ .strict = true, .expand_paths = .off }
    );
    defer parsed.deinit();

    // Use parsed.value as std.json.Value
}
```

## Status & Roadmap

### Completed Features ✅

**Core Implementation:**
- ✅ Full JSON ↔ TOON ↔ ZON encoding/decoding
- ✅ All primitive types (strings, numbers, booleans, null)
- ✅ Smart string quoting (spec-compliant minimal quoting)
- ✅ Nested objects with indentation-based structure
- ✅ Inline arrays for primitives
- ✅ Multi-line arrays for complex values
- ✅ Tabular arrays with `[N]{fields}:` format
- ✅ Automatic tabular eligibility detection
- ✅ Field order preservation (deterministic output)

**Advanced Features:**
- ✅ Alternative delimiters: comma `,`, tab `\t`, pipe `|`
- ✅ Automatic delimiter detection from headers `[N,]` / `[N\t]` / `[N|]`
- ✅ Key folding (`key_folding = .safe`) with configurable depth
- ✅ Path expansion (`expand_paths = .safe`) for dotted keys
- ✅ Strict mode validation (array lengths, field counts, headers)
- ✅ Comprehensive error messages with line/column info
- ✅ Stack overflow protection (`max_depth` limit)

**CLI & Tooling:**
- ✅ CLI with auto-detection (file extension, flags)
- ✅ Stdin/stdout streaming support
- ✅ Explicit commands (`serialize`, `deserialize`)
- ✅ Output format selection (`--json`, `--zon`, `--toon`)
- ✅ Help and usage information

**Testing:**
- ✅ Basic unit tests
- ✅ JSON round-trip tests
- ✅ Spec fixture integration (parse & stringify tests)
- ✅ Reference implementation compatibility tests

### In Progress 🚧

- 🚧 **Format Command**: TOON file reformatting/prettification
  - Parser infrastructure complete
  - Encoder infrastructure complete
  - CLI integration pending

### Planned Enhancements 📋

**Spec Compliance:**
- 📋 Complete conformance test suite coverage
  - All fixtures from `spec/tests/fixtures/encode/`
  - All fixtures from `spec/tests/fixtures/decode/`
  - Edge cases and validation scenarios

**Performance:**
- 📋 Benchmark suite (compare with JSON, official TS implementation)
- 📋 Profile hot paths (tabular arrays, string escaping)
- 📋 Streaming API optimization for large datasets
- 📋 Memory allocation profiling and reduction

**Delimiter Intelligence:**
- 📋 Auto-select optimal delimiter based on content analysis
  - Detect delimiter conflicts in data
  - Suggest best delimiter for token efficiency

**Developer Experience:**
- 📋 API documentation generation (`zig build docs`)
- 📋 More examples and usage patterns
- 📋 Integration guide for Zig projects

### Comparison with Official TypeScript Implementation

**Feature Parity:**
| Feature | toonz (Zig) | @toon-format/toon (TS) | Notes |
|---------|------------|------------------------|-------|
| Core encode/decode | ✅ | ✅ | Full compatibility |
| Tabular arrays | ✅ | ✅ | Same format |
| Delimiters (`,` `\t` `\|`) | ✅ | ✅ | All supported |
| Key folding | ✅ | ✅ | Safe mode |
| Path expansion | ✅ | ✅ | Safe mode |
| Strict validation | ✅ | ✅ | Array lengths, fields |
| Streaming API | ⚠️ | ✅ | Basic support, needs enhancement |
| Format command | 🚧 | ✅ | In progress |
| CLI stats/benchmarks | ❌ | ✅ | Planned |

**Zig-Specific Features:**
- ✅ ZON (Zig Object Notation) support
- ✅ Native Zig type integration
- ✅ Comptime validation
- ✅ Stack overflow protection (not in spec, safety feature)

### Known Limitations

**Current:**
- Format command not yet implemented (CLI stub exists)
- Streaming API less mature than TypeScript version
- No built-in benchmarking/stats in CLI (use external tools)

**Design Choices:**
- `max_depth` default is 256 (prevents stack overflow on malicious input)
  - TypeScript relies on JS engine stack limits
  - This is a safety feature, not a limitation

## Testing

Tests use the official spec fixtures from the `spec/` submodule:

```bash
# Run all tests
zig build test

# Tests include:
# - Basic encode/decode round-trips
# - JSON compatibility
# - Spec fixture conformance (spec/tests/fixtures/)
# - Reference implementation comparison
```

Test fixtures are organized by:
- `spec/tests/fixtures/encode/` - Encoding (JSON → TOON) tests
- `spec/tests/fixtures/decode/` - Decoding (TOON → JSON) tests

Each fixture tests specific features: tabular arrays, delimiters, key folding, edge cases, etc.

## API Reference

### Serialize (JSON/ZON → TOON)

```zig
const toonz = @import("toonz");

// Encode std.json.Value to TOON
const toon_string = try toonz.serialize.stringify(
    json_value,        // std.json.Value
    .{                 // Options
        .indent = 2,
        .delimiter = ',',
        .key_folding = .safe,
        .flatten_depth = null,  // No limit
    },
    allocator
);

// Encode to writer (streaming)
try toonz.serialize.stringifyToWriter(
    json_value,
    options,
    writer,
    allocator
);

// Main API struct
const Stringify = toonz.Stringify;
const result = try Stringify.value(json_value, options, allocator);
```

**Options:**
- `indent: u64` - Number of spaces for indentation (default: `2`)
- `delimiter: ?u8` - Delimiter for arrays: `,`, `\t`, `|` (default: `,`)
- `key_folding: enum { off, safe }` - Collapse single-key chains (default: `.off`)
- `flatten_depth: ?u64` - Max folding depth, `null` = unlimited (default: `null`)

### Deserialize (TOON → JSON/Value)

```zig
const toonz = @import("toonz");

// Parse TOON to std.json.Value
const parsed = try toonz.Parse(std.json.Value).parse(
    allocator,
    toon_input,        // []const u8
    .{                 // Options
        .indent = null,       // Auto-detect
        .strict = true,
        .expand_paths = .safe,
        .max_depth = 256,
    }
);
defer parsed.deinit();
// Use: parsed.value

// Parse to custom Zig type
const MyStruct = struct {
    name: []const u8,
    age: u32,
};
const parsed_struct = try toonz.Parse(MyStruct).parse(
    allocator,
    toon_input,
    .{}
);
defer parsed_struct.deinit();
```

**Options:**
- `indent: ?usize` - Expected indentation, `null` = auto-detect (default: `null`)
- `strict: ?bool` - Enforce strict validation (default: `true`)
- `expand_paths: enum { off, safe }` - Expand dotted keys (default: `.off`)
- `max_depth: usize` - Max nesting depth for safety (default: `256`)

### Value Type

The internal `Value` type represents TOON/JSON values:

```zig
const toonz = @import("toonz");
const Value = toonz.Value;

const value = Value{
    .object = std.StringHashMap(Value).init(allocator),
};

// Types: .null, .bool, .number, .string, .array, .object
switch (value) {
    .object => |obj| // std.StringHashMap(Value)
    .array => |arr| // std.ArrayList(Value)
    .string => |s| // []const u8
    .number => |n| // f64
    .bool => |b| // bool
    .null => // void
}

// Cleanup
value.deinit(allocator);
```

## Project Structure

```
toonz/
├── src/
│   ├── lib/               # Core library
│   │   ├── root.zig       # Public API exports
│   │   ├── Value.zig      # Value type definition
│   │   ├── serialize/     # Encoding (JSON → TOON)
│   │   │   ├── root.zig
│   │   │   ├── Options.zig
│   │   │   ├── encoders.zig
│   │   │   ├── folding.zig
│   │   │   └── ...
│   │   ├── deserialize/   # Decoding (TOON → JSON)
│   │   │   ├── root.zig
│   │   │   ├── Parse.zig
│   │   │   ├── Scanner.zig
│   │   │   ├── expand.zig
│   │   │   └── types/
│   │   └── format/        # Formatting/prettification
│   ├── cli/               # Command-line tool
│   │   ├── main.zig
│   │   └── commands/
│   │       ├── serialize.zig
│   │       ├── deserialize.zig
│   │       └── format.zig
│   └── tests/             # Test suite
│       ├── suite.zig
│       ├── basic.zig
│       ├── json.zig
│       └── spec/          # Spec fixture tests
├── spec/                  # Official spec submodule
│   ├── SPEC.md
│   └── tests/fixtures/
├── js/                    # Official TS implementation
│   └── packages/
├── build.zig
└── README.md
```

## Specification Compliance

This implementation follows the **[TOON Specification v3.0](https://github.com/toon-format/spec/blob/main/SPEC.md)**.

Key spec sections implemented:
- **§3**: Encoding Normalization (Reference Encoder)
- **§4**: Decoding Interpretation (Reference Decoder)
- **§6**: Header Syntax (`[N]{fields}:` format)
- **§7**: Strings and Keys (smart quoting rules)
- **§8**: Objects (indentation-based structure)
- **§9**: Arrays (inline and tabular formats)
- **§11**: Delimiters (comma, tab, pipe with detection)
- **§13**: Conformance and Options (strict mode, folding, expansion)

**Differences from spec:**
- Added `max_depth` safety limit (not in spec, prevents stack overflow)
- ZON support is a Zig-specific extension

## Contributing

Contributions are welcome! This implementation aims for full spec compliance.

**Priority areas:**
1. Complete conformance test coverage
2. Format command implementation
3. Performance optimizations
4. Documentation improvements

**Development:**
```bash
# Clone with submodules
git clone --recursive https://github.com/jassielof/toonz
cd toonz

# Build and test
zig build
zig build test

# Generate docs
zig build docs
```

Please ensure tests pass before submitting PRs.

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Related Projects

- **Official Spec**: [toon-format/spec](https://github.com/toon-format/spec)
- **TypeScript (reference)**: [toon-format/toon](https://github.com/toon-format/toon) (this repo's `js/` submodule)
- **Other implementations**: See the [official README](js/README.md#other-implementations) for Python, Rust, Go, .NET, and more

## Credits

- **TOON Format**: Created by [Johann Schopplich](https://github.com/johannschopplich)
- **Zig Implementation**: [Jassiel Ovando](https://github.com/jassielof)
- **Specification**: [toon-format/spec](https://github.com/toon-format/spec)
