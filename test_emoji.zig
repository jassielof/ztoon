const std = @import("std");
const ztoon = @import("ztoon");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = "hello 👋 world";
    std.debug.print("Input: '{s}' (len={d})\n", .{ input, input.len });

    var decoded = try ztoon.decode(allocator, input, .{});
    defer decoded.deinit(allocator);

    std.debug.print("Decoded type: {}\n", .{decoded});
    if (decoded == .string) {
        std.debug.print("Decoded string: '{s}' (len={d})\n", .{ decoded.string, decoded.string.len });

        const expected = "hello 👋 world";
        if (std.mem.eql(u8, decoded.string, expected)) {
            std.debug.print("✓ Match!\n", .{});
        } else {
            std.debug.print("✗ Mismatch!\n", .{});
            std.debug.print("Expected: '{s}' (len={d})\n", .{ expected, expected.len });

            // Byte-by-byte comparison
            const min_len = @min(decoded.string.len, expected.len);
            for (0..min_len) |i| {
                if (decoded.string[i] != expected[i]) {
                    std.debug.print("First diff at byte {d}: got 0x{x} expected 0x{x}\n", .{ i, decoded.string[i], expected[i] });
                    break;
                }
            }
        }
    }
}
