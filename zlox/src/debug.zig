const std = @import("std");

const value = @import("value.zig");

const Obj = @import("gc.zig").GC.Obj;
const Error = Obj.Error;
const OP = @import("op.zig").OP;
const Compiler = @import("vm.zig").VM.Compiler;
const print = std.debug.print;

pub fn disassembleChunk(ch: *const Obj.Chunk) Error!void {
    print("/=======\\\n", .{});

    var offset: usize = 0;

    while (offset < ch.code.ptr().len) {
        offset = try _disassembleInstruction(ch, offset, true);
    }
    print("\\=======/\n", .{});
}

pub fn print_offset(ch: *const Obj.Chunk, offset: usize) !void {
    print("{d:0>4} ", .{offset});
    const line = try ch.lines.ptr().get(offset);
    if (offset > 0 and line == (try ch.lines.ptr().get(offset - 1))) {
        print("   | ", .{});
    } else {
        print("{d:4} ", .{line});
    }
}

pub fn disassembleInstruction(ch: *const Obj.Chunk, offset: usize) Error!usize {
    return _disassembleInstruction(ch, offset, false);
}

fn _disassembleInstruction(ch: *const Obj.Chunk, offset: usize, print_fn: bool) Error!usize {
    try print_offset(ch, offset);

    const op = try ch.code.ptr().get(offset);
    const name = @tagName(@as(OP, @enumFromInt(op)));

    return switch (op) {
        @intFromEnum(OP.RETURN) => simpleInstruction(name, offset),
        @intFromEnum(OP.NEGATE) => simpleInstruction(name, offset),
        @intFromEnum(OP.ADD) => simpleInstruction(name, offset),
        @intFromEnum(OP.SUBTRACT) => simpleInstruction(name, offset),
        @intFromEnum(OP.DIVIDE) => simpleInstruction(name, offset),
        @intFromEnum(OP.MULTIPLY) => simpleInstruction(name, offset),
        @intFromEnum(OP.TRUE) => simpleInstruction(name, offset),
        @intFromEnum(OP.FALSE) => simpleInstruction(name, offset),
        @intFromEnum(OP.EQUAL) => simpleInstruction(name, offset),
        @intFromEnum(OP.LESS) => simpleInstruction(name, offset),
        @intFromEnum(OP.GREATER) => simpleInstruction(name, offset),
        @intFromEnum(OP.NIL) => simpleInstruction(name, offset),
        @intFromEnum(OP.NOT) => simpleInstruction(name, offset),
        @intFromEnum(OP.CONSTANT) => try constantInstruction(name, ch, offset, print_fn),
        @intFromEnum(OP.DEFINE_GLOBAL) => try constantInstruction(name, ch, offset, print_fn),
        @intFromEnum(OP.METHOD) => try constantInstruction(name, ch, offset, print_fn),
        @intFromEnum(OP.DEFINE_GLOBAL_CONSTANT) => try constantInstruction(name, ch, offset, print_fn),
        @intFromEnum(OP.GET_GLOBAL) => try constantInstruction(name, ch, offset, print_fn),
        @intFromEnum(OP.SET_GLOBAL) => try constantInstruction(name, ch, offset, print_fn),
        @intFromEnum(OP.PRINT) => simpleInstruction(name, offset),
        @intFromEnum(OP.POP) => simpleInstruction(name, offset),
        @intFromEnum(OP.GET_LOCAL) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.SET_LOCAL) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.GET_UPVALUE) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.SET_UPVALUE) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.GET_PROPERTY) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.SET_PROPERTY) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.JUMP_IF_FALSE) => try jumpInstruction(name, true, ch, offset),
        @intFromEnum(OP.JUMP_POP) => simpleInstruction(name, offset),
        @intFromEnum(OP.JUMP) => try jumpInstruction(name, true, ch, offset),
        @intFromEnum(OP.LOOP) => try jumpInstruction(name, false, ch, offset),
        @intFromEnum(OP.SET_INDEX) => simpleInstruction(name, offset),
        @intFromEnum(OP.GET_INDEX) => simpleInstruction(name, offset),
        @intFromEnum(OP.CALL) => try byteInstruction(name, ch, offset),
        @intFromEnum(OP.CLOSURE) => try closureInstruction(name, ch, offset),
        @intFromEnum(OP.CLOSE_UPVALUE) => simpleInstruction(name, offset),
        else => blk: {
            print("Unknown opcode {d} {s}\n", .{ op, name });
            break :blk offset + 1;
        },
    };
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    print("{s}\n", .{name});
    return offset + 1;
}

fn constantInstruction(name: []const u8, ch: *const Obj.Chunk, offset: usize, print_fn: bool) Error!usize {
    const constant = try ch.code.ptr().get(offset + 1);
    const constval = try ch.constants.ptr().get(constant);
    print("{s:<32} {d:4} '{f}'\n", .{ name, constant, constval });
    if (print_fn) {
        if (constval.cast_if(Obj.Type.Function)) |function| {
            try disassembleChunk(function.chunk.ptr());
        } else if (constval.cast_if(Obj.Type.Chunk)) |chunk| {
            try disassembleChunk(chunk);
        }
    }
    return offset + 2;
}

fn byteInstruction(name: []const u8, ch: *const Obj.Chunk, offset: usize) Error!usize {
    print("{s:<32} {d:4}\n", .{ name, try ch.code.ptr().get(offset + 1) });
    return offset + 2;
}

fn jumpInstruction(name: []const u8, sign: bool, ch: *const Obj.Chunk, offset: usize) !usize {
    const msb: u16 = try ch.code.ptr().get(offset + 1);
    const lsb: u16 = try ch.code.ptr().get(offset + 2);
    const jump = (msb << 8) | lsb;

    print("{s:<32} {d:4} -> {d}\n", .{ name, offset, if (sign) offset + 3 + jump else offset + 3 - jump });
    return offset + 3;
}

fn closureInstruction(name: []const u8, ch: *const Obj.Chunk, offset: usize) Error!usize {
    var off = offset + 1;
    const arity = try ch.code.ptr().get(off);
    const count = try ch.code.ptr().get(off + 1);
    off += 2;

    print("{s:<32} {d:4} {d}\n", .{ name, arity, count });
    for (0..count) |_| {
        const tp = try ch.code.ptr().get(off);
        const idx = try ch.code.ptr().get(off + 1);
        try print_offset(ch, off + 1);
        print("{s:<38}|-> {s} {d}\n", .{ "", @tagName(@as(Compiler.Upvalue.Type, @enumFromInt(tp))), idx });
        off += 2;
    }

    return off + 1;
}
