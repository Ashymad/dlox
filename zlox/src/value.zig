const std = @import("std");
const array = @import("array.zig");
const Obj = @import("obj.zig").Obj;

pub const Value = union(enum) {
    number: f64,
    bool: bool,
    nil: void,
    obj: *Obj,

    pub const Tag = std.meta.Tag(@This());

    pub fn print(self: @This()) void {
        switch (self) {
            .number => |val| std.debug.print("{d}", .{val}),
            .bool => |val| std.debug.print("{s}", .{if (val) "true" else "false"}),
            .nil => std.debug.print("nil", .{}),
            .obj => |o| o.print(),
        }
    }

    fn toTag(comptime from: anytype) Tag {
        if (@TypeOf(from) == Obj.Type) {
            return .obj;
        } else {
            return from;
        }
    }

    pub fn is(self: @This(), comptime tag: anytype) bool {
        return switch (self) {
            toTag(tag) => @TypeOf(tag) == Tag or self.obj.is(tag),
            else => false,
        };
    }

    pub fn new(comptime tag: anytype, value: tagType(tag)) @This() {
        return @unionInit(@This(), @tagName(toTag(tag)), value);
    }

    pub fn get(self: @This(), comptime tag: anytype) tagType(tag) {
        return @field(self, @tagName(toTag(tag)));
    }

    pub fn set(self: *@This(), comptime tag: anytype, value: tagType(tag)) void {
        @field(self, @tagName(toTag(tag))) = value;
    }

    pub fn tagType(comptime tag: anytype) type {
        return @TypeOf(@field(@unionInit(@This(), @tagName(toTag(tag)), undefined), @tagName(toTag(tag))));
    }

    pub const ParseNumberError = std.fmt.ParseFloatError;

    pub fn parseNumber(str: []const u8) ParseNumberError!@This() {
        return @This(){ .number = try std.fmt.parseFloat(tagType(Value.number), str) };
    }

    pub fn isTruthy(self: @This()) bool {
        return switch (self) {
            .nil => false,
            .bool => |val| val,
            else => true,
        };
    }

    pub fn equal(self: @This(), other: @This()) bool {
        if (@intFromEnum(self) != @intFromEnum(other)) return false;
        return switch (self) {
            .number => |x| x == other.number,
            .bool => |x| x == other.bool,
            .nil => true,
            .obj => |x| x.equal(other.obj),
        };
    }
};

pub const ValueArray = array.Array(Value, u8, 8);
