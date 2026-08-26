const std = @import("std");

const utils = @import("lib::utils.zig");
const Value = @import("value.zig").Value;

pub fn Obj(fields: anytype) type {
    return packed struct {
        const Self = @This();

        type: Type,
        fields: utils.pack_t(@TypeOf(fields)) = utils.pack(fields),

        pub const List = @import("obj::list.zig").List(fields);
        pub const String = @import("obj::string.zig").String(fields);
        pub const Table = @import("obj::table.zig").Table(fields);
        pub const Function = @import("obj::function.zig").Function(fields);
        pub const Native = @import("obj::native.zig").Native(fields);
        pub const Closure = @import("obj::closure.zig").Closure(fields);
        pub const Upvalue = @import("obj::upvalue.zig").Upvalue(fields);

        pub const Error = error{IllegalCastError} || List.Error || String.Error || Table.Error || Function.Error || Native.Error || List.Error || Closure.Error || Upvalue.Error;

        pub const Type = enum(u8) {
            String,
            Table,
            Function,
            Native,
            List,
            Closure,
            Upvalue,

            pub fn get(self: @This()) type {
                return @field(Self, @tagName(self));
            }
        };

        fn child_name(fqn: []const u8) []const u8 {
            var lastDot = 0;
            for (fqn, 0..) |c, i| {
                if (c == '.') lastDot = i + 1;
                if (c == '(') return fqn[lastDot..i];
            }
            return fqn;
        }

        pub fn is_child(T: type) bool {
            inline for (std.meta.tags(Type)) |tag| {
                if (*tag.get() == T) return true;
            }
            return false;
        }

        pub fn make(child: type) Self {
            return Self{
                .type = @field(Type, child_name(@typeName(child))),
            };
        }

        pub fn init(comptime tp: Type, arg: tp.get().Arg, allocator: std.mem.Allocator) !*Self {
            return (try tp.get().init(arg, allocator)).cast();
        }

        pub fn format(self: anytype, writer: *std.Io.Writer) !void {
            switch (self.type) {
                inline else => |tp| try self._cast(tp).format(writer),
            }
        }
        pub fn eql(self: *const Self, other: *const Self) bool {
            if (!self.is(other.type)) return false;
            return switch (self.type) {
                inline else => |tp| self._cast(tp).eql(other._cast(tp)),
            };
        }
        pub fn free(obj: *Self, allocator: std.mem.Allocator) void {
            return switch (obj.type) {
                inline else => |tp| obj._cast(tp).free(allocator),
            };
        }

        pub fn from(arg: anytype) ?*Self {
            const T = @TypeOf(arg);

            return switch (T) {
                Value => switch (arg) {
                    .obj => |o| Self.from(o),
                    else => null,
                },
                *Self => arg,
                else => if (comptime Self.is_child(T)) arg.cast() else null,
            };
        }

        pub fn is(self: *const Self, tp: Type) bool {
            return self.type == tp;
        }

        pub fn cast(self: anytype, comptime tp: Type) Error!utils.copy_const(@TypeOf(self), *tp.get()) {
            return if (self.is(tp)) self._cast(tp) else Error.IllegalCastError;
        }

        pub fn cast_if(self: anytype, comptime tp: Type) ?utils.copy_const(@TypeOf(self), *tp.get()) {
            return if (self.is(tp)) self._cast(tp) else null;
        }

        fn _cast(self: anytype, comptime tp: Type) utils.copy_const(@TypeOf(self), *tp.get()) {
            return @ptrCast(@alignCast(self));
        }
    };
}
