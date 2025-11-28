const std = @import("std");
const toonz = @import("toonz");
const serialize_cmd = @import("commands/serialize.zig");
const deserialize_cmd = @import("commands/deserialize.zig");
const format_cmd = @import("commands/format.zig");
const errors = @import("errors.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    // Parse command or detect from arguments
    const command = parseCommand(&args, allocator) catch |err| {
        printUsage();
        return err;
    };

    switch (command) {
        .serialize => |cmd| {
            defer freeCommandStrings(cmd, allocator);
            try serialize_cmd.run(cmd, allocator);
        },
        .deserialize => |cmd| {
            defer freeCommandStrings(cmd, allocator);
            try deserialize_cmd.run(cmd, allocator);
        },
        .format => {
            try format_cmd.run(allocator);
        },
        .auto => |cmd| {
            // Auto-detect based on file extension or flags
            defer freeAutoCommandStrings(cmd, allocator);
            try runAuto(cmd, allocator);
        },
    }
}

const Command = union(enum) {
    serialize: serialize_cmd.Command,
    deserialize: deserialize_cmd.Command,
    format: void,
    auto: AutoCommand,
};

const AutoCommand = struct {
    input_path: ?[]const u8,
    output_path: ?[]const u8,
    output_format: ?OutputFormat,
    serialize_opts: serialize_cmd.Options,
    deserialize_opts: deserialize_cmd.Options,
};

const OutputFormat = enum {
    json,
    zon,
    toon,
};

fn parseCommand(args: *std.process.ArgIterator, allocator: std.mem.Allocator) !Command {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var output_format: ?OutputFormat = null;
    var command_type: ?enum { serialize, deserialize, format, auto } = null;

    // Collect all arguments first
    var arg_list = std.array_list.Managed([]const u8).init(allocator);
    defer arg_list.deinit();

    while (args.next()) |arg| {
        try arg_list.append(arg);
    }

    // Parse flags and arguments
    var i: usize = 0;
    while (i < arg_list.items.len) : (i += 1) {
        const arg = arg_list.items[i];

        // Handle help flag
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "serialize") or std.mem.eql(u8, arg, "deserialize") or std.mem.eql(u8, arg, "format")) {
            if (command_type != null) {
                return error.InvalidArguments;
            }
            if (std.mem.eql(u8, arg, "serialize")) {
                command_type = .serialize;
            } else if (std.mem.eql(u8, arg, "deserialize")) {
                command_type = .deserialize;
            } else if (std.mem.eql(u8, arg, "format")) {
                command_type = .format;
            }
        } else if (std.mem.eql(u8, arg, "--zon") or std.mem.eql(u8, arg, "-z")) {
            output_format = .zon;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "--toon") or std.mem.eql(u8, arg, "-t")) {
            output_format = .toon;
        } else if (std.mem.startsWith(u8, arg, "-o=") or std.mem.startsWith(u8, arg, "--output=")) {
            const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
            output_path = try allocator.dupe(u8, arg[eq_pos + 1 ..]);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= arg_list.items.len) return error.InvalidArguments;
            output_path = try allocator.dupe(u8, arg_list.items[i]);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (input_path == null) {
                input_path = try allocator.dupe(u8, arg);
            } else {
                return error.InvalidArguments;
            }
        } else {
            // Unknown flag, might be for serialize/deserialize commands
            // We'll handle those in the command parsers
            // For now, return error for unknown flags in auto mode
            if (command_type == null) {
                return error.InvalidArguments;
            }
        }
    }

    // If explicit command, parse it
    if (command_type) |cmd_type| {
        // Recreate arg iterator for command parsing
        var cmd_args = std.array_list.Managed([]const u8).init(allocator);
        defer cmd_args.deinit();

        // Skip the command name and collect remaining args
        var found_cmd = false;
        for (arg_list.items) |arg| {
            if (!found_cmd and (std.mem.eql(u8, arg, "serialize") or std.mem.eql(u8, arg, "deserialize"))) {
                found_cmd = true;
                continue;
            }
            if (found_cmd) {
                try cmd_args.append(arg);
            }
        }

        switch (cmd_type) {
            .serialize => {
                const cmd = try serialize_cmd.parseCommand(cmd_args.items, allocator, input_path, output_path);
                return Command{ .serialize = cmd };
            },
            .deserialize => {
                const cmd = try deserialize_cmd.parseCommand(cmd_args.items, allocator, input_path, output_path);
                return Command{ .deserialize = cmd };
            },
            .format => {
                return Command{ .format = {} };
            },
            .auto => unreachable,
        }
    }

    // Auto-detect mode
    return Command{
        .auto = AutoCommand{
            .input_path = input_path,
            .output_path = output_path,
            .output_format = output_format,
            .serialize_opts = serialize_cmd.Options{},
            .deserialize_opts = deserialize_cmd.Options{},
        },
    };
}

fn runAuto(cmd: AutoCommand, allocator: std.mem.Allocator) !void {
    const input_source: serialize_cmd.InputSource = if (cmd.input_path) |path|
        if (std.mem.eql(u8, path, "-"))
            serialize_cmd.InputSource{ .stdin = {} }
        else
            serialize_cmd.InputSource{ .file = path }
    else
        serialize_cmd.InputSource{ .stdin = {} };

    // Detect input format
    const input_format = detectInputFormat(cmd.input_path, cmd.output_format);

    // Determine conversion direction
    const mode = detectMode(input_format, cmd.output_format);

    switch (mode) {
        .serialize => {
            // JSON/ZON -> TOON
            const serialize_cmd_obj = serialize_cmd.Command{
                .input_source = input_source,
                .output_path = cmd.output_path,
                .options = cmd.serialize_opts,
            };
            try serialize_cmd.run(serialize_cmd_obj, allocator);
        },
        .deserialize => {
            // TOON -> JSON/ZON
            const output_fmt: deserialize_cmd.OutputFormat = if (cmd.output_format) |fmt|
                switch (fmt) {
                    .json => .json,
                    .zon => .zon,
                    .toon => .json, // Default to JSON if toon specified (shouldn't happen)
                }
            else
                .json;

            const deserialize_input_source: deserialize_cmd.InputSource = switch (input_source) {
                .file => |path| deserialize_cmd.InputSource{ .file = path },
                .stdin => deserialize_cmd.InputSource{ .stdin = {} },
            };

            const deserialize_cmd_obj = deserialize_cmd.Command{
                .input_source = deserialize_input_source,
                .output_path = cmd.output_path,
                .output_format = output_fmt,
                .options = cmd.deserialize_opts,
            };
            try deserialize_cmd.run(deserialize_cmd_obj, allocator);
        },
    }
}

const InputFormat = enum {
    json,
    zon,
    toon,
    unknown,
};

const Mode = enum {
    serialize,
    deserialize,
};

fn detectInputFormat(input_path: ?[]const u8, output_format: ?OutputFormat) InputFormat {
    if (input_path) |path| {
        if (std.mem.endsWith(u8, path, ".json")) {
            return .json;
        } else if (std.mem.endsWith(u8, path, ".zon")) {
            return .zon;
        } else if (std.mem.endsWith(u8, path, ".toon")) {
            return .toon;
        }
    }

    // If output format is specified and input is stdin, infer from output
    if (output_format) |fmt| {
        return switch (fmt) {
            .json, .zon => .toon, // If output is JSON/ZON, input must be TOON
            .toon => .unknown, // If output is TOON, input could be JSON or ZON
        };
    }

    return .unknown;
}

fn detectMode(input_format: InputFormat, output_format: ?OutputFormat) Mode {
    // If output format is explicitly specified, use it
    if (output_format) |fmt| {
        return switch (fmt) {
            .json, .zon => .deserialize, // TOON -> JSON/ZON
            .toon => .serialize, // JSON/ZON -> TOON
        };
    }

    // Auto-detect based on input format
    return switch (input_format) {
        .json, .zon => .serialize, // JSON/ZON -> TOON
        .toon => .deserialize, // TOON -> JSON (default)
        .unknown => .serialize, // Default: assume JSON -> TOON
    };
}


fn freeCommandStrings(cmd: anytype, allocator: std.mem.Allocator) void {
    const T = @TypeOf(cmd);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                const field_value = @field(cmd, field.name);
                const FieldType = @TypeOf(field_value);

                // Handle optional strings
                if (FieldType == ?[]const u8) {
                    if (field_value) |path| {
                        allocator.free(path);
                    }
                }
                // Handle InputSource union (file/stdin)
                else if (FieldType == serialize_cmd.InputSource) {
                    switch (field_value) {
                        .file => |path| allocator.free(path),
                        .stdin => {},
                    }
                }
                // Handle deserialize InputSource
                else if (FieldType == deserialize_cmd.InputSource) {
                    switch (field_value) {
                        .file => |path| allocator.free(path),
                        .stdin => {},
                    }
                }
            }
        },
        else => {},
    }
}

fn freeAutoCommandStrings(cmd: AutoCommand, allocator: std.mem.Allocator) void {
    if (cmd.input_path) |path| {
        allocator.free(path);
    }
    if (cmd.output_path) |path| {
        allocator.free(path);
    }
}

fn printUsage() void {
    const stderr_file = std.fs.File.stderr();
    stderr_file.writeAll(
        \\Usage: toonz [command] [options] [input]
        \\
        \\Commands:
        \\  serialize    Convert JSON or ZON to TOON
        \\  deserialize  Convert TOON to JSON or ZON
        \\  format       Format TOON file (TODO)
        \\
        \\Options:
        \\  -o, --output <path>  Output file path (default: stdout)
        \\  --zon, -z            Output as ZON format
        \\  --json, -j           Output as JSON format (default for deserialize)
        \\  --toon, -t           Output as TOON format
        \\
        \\Examples:
        \\  toonz sample.json              # Convert JSON to TOON
        \\  toonz sample.toon              # Convert TOON to JSON
        \\  toonz sample.zon               # Convert ZON to TOON
        \\  toonz sample.toon --zon        # Convert TOON to ZON
        \\  echo '...' | toonz serialize   # Convert JSON/ZON from stdin to TOON
        \\  echo '...' | toonz deserialize  # Convert TOON from stdin to JSON
        \\
    ) catch {};
}
