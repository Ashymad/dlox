const std = @import("std");

const utils = @import("lib::utils.zig");
const table = @import("lib::table.zig");
const hash = @import("hash.zig");

const Packed = @import("lib::packed.zig").Packed;
const Value = @import("value.zig").Value;
const Obj = @import("obj.zig").Obj;

pub fn Instance(fields: anytype) type {
    const Super = Obj(fields);

    return packed struct {
        const Self = @This();

        pub const Arg = *Super.Class;
        pub const Error = error{OutOfMemory};

        pub const Fields = table.Table(*Super.String, Value, hash.hash_t(*Super.String), Super.String.eql);

        obj: Super,
        cls: Packed(*Super.Class),
        fields: Packed(*Fields),

        pub fn init(cls: Arg, allocator: std.mem.Allocator) Error!*Self {
            const self: *Self = try allocator.create(Self);
            self.* = Self{
                .obj = Super.make(Self),
                .cls = Packed(*Super.Class).init(cls),
                .fields = try Packed(*Self.Fields).create2(allocator, Fields.init(allocator)),
            };
            return self;
        }

        pub fn cast(self: anytype) utils.copy_const(@TypeOf(self), *Super) {
            return @ptrCast(self);
        }

        pub fn format(_: *const Self, writer: *std.Io.Writer) !void {
            _ = try writer.write("<Instance>");
        }

        pub fn eql(_: *const Self, _: *const Self) bool {
            return false;
        }

        pub fn free(self: *const Self, allocator: std.mem.Allocator) void {
            self.fields.ptr().deinit();
            self.fields.destroy(allocator);
            allocator.destroy(self);
        }
    };
}
