const std = @import("std");

const array = @import("lib::array.zig");
const utils = @import("lib::utils.zig");

const Obj = @import("gc.zig").GC.Obj;

pub const Value = union(enum) {
    number: f64,
    char: u8,
    bool: bool,
    nil: void,
    obj: *Obj,

    const Self = @This();
    pub const Tag = std.meta.Tag(Self);

    pub fn format(self: Self, writer: *std.Io.Writer) !void {
        switch (self) {
            .number => |val| try writer.print("{d}", .{val}),
            .char => |val| try writer.writeAll(&[_]u8{val}),
            .bool => |val| try writer.writeAll(if (val) "true" else "false"),
            .nil => try writer.writeAll("nil"),
            .obj => |o| try o.format(writer),
        }
    }

    pub fn tagNameOf(T: type) []const u8 {
        return @tagName(utils.tagFromType(Self, T));
    }

    pub fn typeName(self: Self) []const u8 {
        return switch (self) {
            .obj => |o| @tagName(o.type),
            inline else => |tp| tagNameOf(@TypeOf(tp)),
        };
    }

    pub fn init(val: anytype) Self {
        return @unionInit(Self, tagNameOf(@TypeOf(val)), val);
    }

    fn toTag(comptime from: anytype) Tag {
        return if (@TypeOf(from) == Obj.Type)
            .obj
        else
            from;
    }

    pub fn is(self: Self, comptime tag: anytype) bool {
        return switch (self) {
            toTag(tag) => @TypeOf(tag) == Tag or self.obj.is(tag),
            else => false,
        };
    }

    pub fn cast_if(self: Self, comptime tag: anytype) if (@TypeOf(tag) == Tag) ?utils.typeFromTag(Self, tag) else ?*Obj.Type.get(tag) {
        return switch (self) {
            toTag(tag) => if (@TypeOf(tag) == Tag) self.get(tag) else self.obj.cast_if(tag),
            else => null,
        };
    }

    pub fn get(self: Self, comptime tag: anytype) tagType(tag) {
        return @field(self, @tagName(toTag(tag)));
    }

    pub fn set(self: *Self, comptime tag: anytype, value: tagType(tag)) void {
        @field(self, @tagName(toTag(tag))) = value;
    }

    pub fn tagType(comptime tag: anytype) type {
        return utils.typeFromTag(Self, toTag(tag));
    }

    pub const ParseNumberError = std.fmt.ParseFloatError;

    pub fn parseNumber(str: []const u8) ParseNumberError!Self {
        return Self{ .number = try std.fmt.parseFloat(tagType(Value.number), str) };
    }

    pub fn isTruthy(self: Self) bool {
        return switch (self) {
            .nil => false,
            .bool => |val| val,
            else => true,
        };
    }

    pub fn eql(self: Self, other: Self) bool {
        if (@intFromEnum(self) != @intFromEnum(other)) return false;
        return switch (self) {
            .number => |x| x == other.number,
            .char => |x| x == other.char,
            .bool => |x| x == other.bool,
            .nil => true,
            .obj => |x| x.eql(other.obj),
        };
    }
};
