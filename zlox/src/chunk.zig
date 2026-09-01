const std = @import("std");

const array = @import("lib::array.zig");

const Value = @import("value.zig").Value;

pub const OP = enum(u8) {
    CONSTANT,
    NIL,
    TRUE,
    FALSE,
    EQUAL,
    GREATER,
    LESS,
    RETURN,
    NEGATE,
    ADD,
    SUBTRACT,
    MULTIPLY,
    DIVIDE,
    NOT,
    PRINT,
    POP,
    DEFINE_GLOBAL,
    DEFINE_GLOBAL_CONSTANT,
    GET_GLOBAL,
    SET_GLOBAL,
    GET_LOCAL,
    SET_LOCAL,
    GET_PROPERTY,
    SET_PROPERTY,
    GET_UPVALUE,
    SET_UPVALUE,
    JUMP_IF_FALSE,
    JUMP,
    JUMP_POP,
    LOOP,
    SET_INDEX,
    GET_INDEX,
    CALL,
    CLOSURE,
    CLOSE_UPVALUE,
};

pub const Chunk = struct {
    pub const Error = error{OutOfMemory};

    pub fn init(allocator: std.mem.Allocator) Error!@This() {
        return @This(){
            .code = try array.Array(u8, usize, 8).init(allocator),
            .constants = try Value.Array.init(allocator),
            .lines = try array.RLEArray(i32, 8).init(allocator),
        };
    }

    pub fn write(self: *@This(), byte: u8, line: i32) Error!void {
        try self.code.add(byte);
        try self.lines.add(line);
    }

    pub fn writeOP(self: *@This(), op: OP, line: i32) Error!void {
        try self.write(@intFromEnum(op), line);
    }

    pub fn addConstant(self: *@This(), val: Value) Error!u8 {
        for (self.constants.slice(), 0..) |el, i| {
            if (el.eql(val)) {
                return @intCast(i);
            }
        }
        try self.constants.add(val);
        return self.constants.len - 1;
    }

    pub fn deinit(self: *@This()) void {
        self.constants.deinit();
        self.lines.deinit();
        self.code.deinit();
    }

    code: array.Array(u8, usize, 8),
    constants: Value.Array,
    lines: array.RLEArray(i32, 8),
};
