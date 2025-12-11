//! Deserialize command: Convert TOON to JSON or ZON

const std = @import("std");
const toonz = @import("toonz");
const errors = @import("../errors.zig");

pub const Options = toonz.Parse.Options;

pub const Command = struct {
    input_source: InputSource,
    output_path: ?[]const u8,
    output_format: OutputFormat,
    options: Options,
};

pub const InputSource = union(enum) {
    file: []const u8,
    stdin: void,
};

pub const OutputFormat = enum {
    json,
    zon,
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
    var output_format: OutputFormat = .json;

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
        } else if (std.mem.eql(u8, arg, "--zon") or std.mem.eql(u8, arg, "-z")) {
            output_format = .zon;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            output_format = .json;
        } else if (std.mem.startsWith(u8, arg, "--indent=")) {
            const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
            const indent_str = arg[eq_pos + 1 ..];
            opts.indent = try std.fmt.parseInt(usize, indent_str, 10);
        } else if (std.mem.eql(u8, arg, "--indent")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            opts.indent = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--strict=true") or std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, arg, "--strict=false")) {
            opts.strict = false;
        } else if (std.mem.eql(u8, arg, "--expand-paths=off") or std.mem.eql(u8, arg, "--expandPaths=off")) {
            opts.expand_paths = .off;
        } else if (std.mem.eql(u8, arg, "--expand-paths=safe") or std.mem.eql(u8, arg, "--expandPaths=safe")) {
            opts.expand_paths = .safe;
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
        .output_format = output_format,
        .options = opts,
    };
}

pub fn run(cmd: Command, allocator: std.mem.Allocator) !void {
    // Read input
    const input_content = try readInput(cmd.input_source, allocator);
    defer allocator.free(input_content);

    // Parse TOON
    const parsed = try toonz.Parse.fromSlice(std.json.Value, allocator, input_content, cmd.options);
    defer parsed.deinit();

    // Convert to output format
    switch (cmd.output_format) {
        .json => {
            const json_output = try toJson(parsed.value, allocator, cmd.options.indent orelse 2);
            defer allocator.free(json_output);
            try writeOutput(json_output, cmd.output_path);
        },
        .zon => {
            const zon_output = try toZon(parsed.value, allocator);
            defer allocator.free(zon_output);
            try writeOutput(zon_output, cmd.output_path);
        },
    }
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

fn toJson(value: std.json.Value, allocator: std.mem.Allocator, indent: usize) ![]const u8 {
    _ = indent; // Indent not supported in Zig 0.15's JSON stringify
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const writer = &out.writer;
    try std.json.Stringify.value(value, .{}, writer);
    const json_str = out.written();

    return try allocator.dupe(u8, json_str);
}

fn toZon(value: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    // Convert std.json.Value to ZON format
    // ZON format is similar to Zig struct literals
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();

    const writer = list.writer();
    try writeZonValue(value, writer, allocator, 0);

    return try list.toOwnedSlice();
}

fn writeZonValue(value: std.json.Value, writer: anytype, allocator: std.mem.Allocator, indent: usize) !void {
    const indent_str = "  ";
    const current_indent = indent_str[0..indent];

    switch (value) {
        .null => try writer.print("null", .{}),
        .bool => |b| try writer.print("{}", .{b}),
        .integer => |i| try writer.print("{}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| try writer.print("{s}", .{s}),
        .string => |s| {
            // Escape string for ZON
            try writer.print("\"", .{});
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                switch (c) {
                    '\\' => try writer.print("\\\\", .{}),
                    '"' => try writer.print("\\\"", .{}),
                    '\n' => try writer.print("\\n", .{}),
                    '\r' => try writer.print("\\r", .{}),
                    '\t' => try writer.print("\\t", .{}),
                    else => try writer.print("{c}", .{c}),
                }
            }
            try writer.print("\"", .{});
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try writer.print(".{{}}", .{});
                return;
            }
            try writer.print(".{{", .{});
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("\n{s}", .{current_indent});
                try writer.print(indent_str, .{});
                try writeZonValue(item, writer, allocator, indent + 2);
            }
            try writer.print("\n{s}", .{current_indent});
            try writer.print("}}", .{});
        },
        .object => |obj| {
            if (obj.count() == 0) {
                try writer.print(".{{}}", .{});
                return;
            }
            try writer.print(".{{", .{});
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.print(",", .{});
                first = false;
                try writer.print("\n{s}", .{current_indent});
                try writer.print(indent_str, .{});

                // Write key (check if it's a valid identifier)
                const key = entry.key_ptr.*;
                if (isValidIdentifier(key)) {
                    try writer.print(".{s} = ", .{key});
                } else {
                    try writer.print("\"{s}\" = ", .{key});
                }

                try writeZonValue(entry.value_ptr.*, writer, allocator, indent + 2);
            }
            try writer.print("\n{s}", .{current_indent});
            try writer.print("}}", .{});
        },
    }
}

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;

    // First character must be letter or underscore
    const first = s[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    // Rest must be alphanumeric or underscore
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    return true;
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
