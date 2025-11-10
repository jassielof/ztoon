# Z-TOON: Zig TOON

A Zig implementation of the TOON (Token-Oriented Object Notation) format, version 1.4.

## What is TOON?

TOON is a line-oriented, indentation-based text format that encodes the JSON data model with explicit structure and minimal quoting. It's particularly efficient for arrays of uniform objects, providing a more compact and readable alternative to JSON for structured data.

See the [full specification](https://github.com/toon-format/spec) for details in depth.

## Features

- [x] **Core Encoding/Decoding**: Full JSON ↔ TOON conversion
- [x] **Primitives**: strings, numbers, booleans, null with smart quoting
- [x] **Objects**: Nested objects with indentation-based structure
- [x] **Arrays**: Both inline (primitives) and multi-line (objects/nested)
- [x] **Tabular Arrays**: Compact `[N]{field1,field2}:` format for uniform object arrays
- [x] **Alternative Delimiters**: Comma (default), tab (`\t`), and pipe (`|`) support
- [x] **Delimiter Detection**: Automatic delimiter detection in array headers `[N<delim>]`
- [x] **CLI Tool**: Encode and decode via command line or pipes

## Building

Requires Zig 0.15.2 or later:

```
zig build
```

The binary will be available at `./zig-out/bin/ztoon`.

## Usage

### CLI

**Encode JSON to TOON:**
```bash
echo '{"name": "Alice", "age": 30}' | ./zig-out/bin/ztoon encode
```

Output:
```
name: Alice
age: 30
```

**Decode TOON to JSON:**
```bash
echo 'name: Alice
age: 30' | ./zig-out/bin/ztoon decode
```

Output:
```json
{
  "name": "Alice",
  "age": 30
}
```

**From files:**
```bash
./zig-out/bin/ztoon encode input.json
./zig-out/bin/ztoon decode input.toon
```

### Library

```zig
const std = @import("std");
const toon = @import("ztoon");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a value
    var obj = std.StringHashMap(toon.Value).init(allocator);
    defer obj.deinit();

    try obj.put("name", toon.Value{ .string = "Alice" });
    try obj.put("age", toon.Value{ .number = 30 });

    const value = toon.Value{ .object = obj };
    defer value.deinit(allocator);

    // Encode to TOON
    const encoded = try toon.encode(allocator, value, .{});
    defer allocator.free(encoded);

    std.debug.print("TOON: {s}\n", .{encoded});

    // Decode from TOON
    var decoded = try toon.decode(allocator, encoded, .{});
    defer decoded.deinit(allocator);
}
```

## Examples

### Simple Object
```json
{"name": "Alice", "age": 30, "active": true}
```
↓
```toon
name: Alice
age: 30
active: true
```

### Nested Objects
```json
{"user": {"name": "Alice", "settings": {"theme": "dark"}}}
```
↓
```toon
user:
  name: Alice
  settings:
    theme: dark
```

### Tabular Array (Uniform Objects)
```json
{"items": [
  {"sku": "A1", "qty": 2, "price": 9.99},
  {"sku": "B2", "qty": 1, "price": 14.5}
]}
```
↓
```toon
items:[2]{sku,price,qty}:
  A1,9.99,2
  B2,14.5,1
```

### Pipe-Delimited Tabular Array
```json
{"users": [
  {"name": "Alice", "role": "admin"},
  {"name": "Bob", "role": "dev"}
]}
```
↓
```toon
users:[2|]{name|role}:
  Alice|admin
  Bob|dev
```

### Primitive Array
```json
{"items": [1, 2, 3, 4, 5]}
```
↓
```toon
items[5]: 1,2,3,4,5
```

### Array of Objects (Non-Uniform)
```json
{"users": [{"name": "Alice", "id": 1}, {"name": "Bob", "id": 2}]}
```
↓
```toon
users[2]:
  -
    name: Alice
    id: 1
  -
    name: Bob
    id: 2
```

## Status & Roadmap

### Implemented ✅
- Core TOON encoder and decoder
- Nested objects with indentation
- Tabular arrays with field lists
- Alternative delimiters (comma, tab, pipe)
- Delimiter detection from array headers
- Smart string quoting
- CLI tool

### In Progress 🔄
- Field order preservation (currently HashMap iteration order)
- Comprehensive error messages

### Planned 📋
- Length markers (`#` in array headers) - parsing supported, encoding optional
- Strict mode validation (length mismatches, malformed headers)
- Conformance test suite from `spec/tests/fixtures/`
- Performance optimizations
- Benchmarks vs JSON

### Known Limitations ⚠️
- Field order in tabular arrays depends on HashMap iteration (not deterministic)
- Limited validation in non-strict mode
- Some edge cases from spec may not be fully covered

## Next Steps

To continue improving this implementation:

1. **Field Order Preservation**: Use an ordered map structure to preserve JSON key order in tabular arrays
2. **Conformance Tests**: Load and run test fixtures from `spec/tests/fixtures/` for full spec compliance
3. **Strict Mode**: Implement validation for length mismatches, invalid characters, and malformed headers
4. **Better Delimiters**: Auto-select optimal delimiter on encode based on content analysis
5. **Error Handling**: Improve error messages with line numbers and context
6. **Performance**: Profile and optimize hot paths, especially for large tabular arrays
7. **Documentation**: Add inline documentation and more usage examples

## Testing

Currently tested manually with various inputs. Run some quick tests:

```bash
# Test nested objects
echo '{"a":1,"b":{"c":2}}' | ./zig-out/bin/ztoon encode | ./zig-out/bin/ztoon decode

# Test tabular arrays
echo '{"items":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}' | ./zig-out/bin/ztoon encode

# Test with different delimiters
printf 'items:[2|]{name|role}:\n  Alice|admin\n  Bob|dev' | ./zig-out/bin/ztoon decode
```
