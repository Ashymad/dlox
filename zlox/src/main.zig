const std = @import("std");
const chunk = @import("chunk.zig");
const debug = @import("debug.zig");

pub fn main() anyerror!u8 {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!allocator.deinit());
    var ch = try chunk.Chunk.init(allocator.allocator());
    defer ch.deinit();

    const constant = try ch.addConstant(1.2);
    try ch.write(@enumToInt(chunk.OP.CONSTANT), 123);
    try ch.write(constant, 123);

    try ch.write(@enumToInt(chunk.OP.RETURN), 123);

    try debug.disassembleChunk(ch, "test chunk");
    return 0;
}
