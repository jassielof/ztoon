//! Serialize command: Convert JSON or ZON to TOON

const std = @import("std");
const toonz = @import("toonz");
const errors = @import("../errors.zig");

pub const Options = toonz.serialize.Options;

pub const Command = struct {
    input_source: InputSource,
    output_path: ?[]const u8,
    options: Options,
};

pub const InputSource = union(enum) {
    file: []const u8,
    stdin: void,
};

pub fn parseCommand(
    args: []const []const u8,
    allocator: std.mem.Allocator,
    input_path: ?[]const u8,
    output_path: ?[]const u8,
) !Command {
    var opts = Options{};
    var parsed_input_path = input_path;
    var parsed_output_path = output_path;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed_output_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-o=") or std.mem.startsWith(u8, arg, "--output=")) {
            const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
            parsed_output_path = try allocator.dupe(u8, arg[eq_pos + 1 ..]);
        } else if (std.mem.startsWith(u8, arg, "--indent=")) {
            const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
            const indent_str = arg[eq_pos + 1 ..];
            opts.indent = try std.fmt.parseInt(u64, indent_str, 10);
        } else if (std.mem.eql(u8, arg, "--indent")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.indent = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
            const delim_str = arg[eq_pos + 1 ..];
            if (delim_str.len != 1) return error.InvalidArguments;
            opts.delimiter = delim_str[0];
        } else if (std.mem.eql(u8, arg, "--delimiter")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            if (args[i].len != 1) return error.InvalidArguments;
            opts.delimiter = args[i][0];
        } else if (std.mem.eql(u8, arg, "--key-folding=off") or std.mem.eql(u8, arg, "--keyFolding=off")) {
            opts.key_folding = .off;
        } else if (std.mem.eql(u8, arg, "--key-folding=safe") or std.mem.eql(u8, arg, "--keyFolding=safe")) {
            opts.key_folding = .safe;
        } else if (std.mem.startsWith(u8, arg, "--flatten-depth=")) {
            const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
            const depth_str = arg[eq_pos + 1 ..];
            opts.flatten_depth = try std.fmt.parseInt(u64, depth_str, 10);
        } else if (std.mem.eql(u8, arg, "--flatten-depth")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.flatten_depth = try std.fmt.parseInt(u64, args[i], 10);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (parsed_input_path == null) {
                parsed_input_path = try allocator.dupe(u8, arg);
            } else {
                return error.InvalidArguments;
            }
        }
    }

    const input_source: InputSource = if (parsed_input_path) |path|
        if (std.mem.eql(u8, path, "-"))
            InputSource{ .stdin = {} }
        else
            InputSource{ .file = path }
    else
        InputSource{ .stdin = {} };

    return Command{
        .input_source = input_source,
        .output_path = parsed_output_path,
        .options = opts,
    };
}

pub fn run(cmd: Command, allocator: std.mem.Allocator) !void {
    // Read input
    const input_content = try readInput(cmd.input_source, allocator);
    defer allocator.free(input_content);

    // Detect input format
    const input_format = detectInputFormat(cmd.input_source, input_content);

    // Parse input based on format
    const json_value = switch (input_format) {
        .json => try parseJson(input_content, allocator),
        .zon => try parseZon(input_content, allocator),
        .toon => return error.InvalidArguments, // Can't serialize TOON to TOON
    };
    defer json_value.deinit();

    // Convert to TOON
    const toon_output = try toonz.serialize.stringify(json_value.value, cmd.options, allocator);
    defer allocator.free(toon_output);

    // Write output
    try writeOutput(toon_output, cmd.output_path);
}

fn readInput(source: InputSource, allocator: std.mem.Allocator) ![]const u8 {
    switch (source) {
        .file => |path| {
            const content = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
            return content;
        },
        .stdin => {
            const stdin_file = std.fs.File.stdin();
            var buffer = std.array_list.Managed(u8).init(allocator);
            defer buffer.deinit();

            var read_buf: [4096]u8 = undefined;
            while (true) {
                const bytes_read = try stdin_file.read(read_buf[0..]);
                if (bytes_read == 0) break;
                try buffer.appendSlice(read_buf[0..bytes_read]);
            }

            return try buffer.toOwnedSlice();
        },
    }
}

const InputFormat = enum {
    json,
    zon,
    toon,
};

fn detectInputFormat(source: InputSource, content: []const u8) InputFormat {
    switch (source) {
        .file => |path| {
            if (std.mem.endsWith(u8, path, ".json")) {
                return .json;
            } else if (std.mem.endsWith(u8, path, ".zon")) {
                return .zon;
            } else if (std.mem.endsWith(u8, path, ".toon")) {
                return .toon;
            }
        },
        .stdin => {},
    }

    // Try to detect from content
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (trimmed.len > 0) {
        if (trimmed[0] == '{' or trimmed[0] == '[') {
            return .json;
        } else if (trimmed[0] == '.') {
            return .zon;
        }
    }

    // Default to JSON
    return .json;
}

fn parseJson(content: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
}

fn parseZon(content: []const u8, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    // ZON parsing in Zig requires compile-time known types, which makes it
    // difficult to parse arbitrary ZON into std.json.Value.
    // For now, we'll return an error indicating limited ZON support.
    // A full implementation would require a more sophisticated ZON-to-JSON converter.
    _ = content;
    _ = allocator;
    return error.ZonNotSupported;
}

fn deepCopyJsonValue(value: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = std.json.Array.init(allocator);
            for (arr.items) |item| {
                try new_arr.append(try deepCopyJsonValue(item, allocator));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try deepCopyJsonValue(entry.value_ptr.*, allocator);
                try new_obj.put(key, val);
            }
            break :blk .{ .object = new_obj };
        },
    };
}

fn writeOutput(content: []const u8, output_path: ?[]const u8) !void {
    if (output_path) |path| {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
    } else {
        const stdout_file = std.fs.File.stdout();
        try stdout_file.writeAll(content);
        try stdout_file.writeAll("\n");
    }
}
