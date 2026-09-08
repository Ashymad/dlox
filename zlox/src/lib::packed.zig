const std = @import("std");

const utils = @import("lib::utils.zig");

const Error = error{NullPointer};

pub fn Pointer(Type: type) type {
    return packed struct {
        const Self = @This();

        pub const optional = utils.is_type(Type, "optional");

        pub const Ptr = if (optional) @typeInfo(Type).optional.child else Type;
        pub const Val = @typeInfo(Ptr).pointer.child;
        pub const Opt = if (optional) ?Val else Val;

        _ptr: usize,

        pub fn create(allocator: std.mem.Allocator) !Self {
            return Self.init(try allocator.create(Val));
        }

        pub fn init(arg: Type) Self {
            return Self{
                ._ptr = if (utils.optional(arg)) |val|
                    @intFromPtr(val)
                else
                    0,
            };
        }

        pub fn ptr(self: Self) Type {
            return if (optional and self._ptr == 0)
                null
            else
                @ptrFromInt(self._ptr);
        }

        pub fn get(self: Self) Opt {
            return if (utils.optional(self.ptr())) |pointer|
                pointer.*
            else if (optional)
                null
            else
                unreachable;
        }

        pub fn set(self: Self, val: Val) if (optional) Error.NullPointer!void else void {
            if (utils.optional(self.ptr())) |pointer|
                pointer.* = val
            else if (optional)
                return Error.NullPointer
            else
                unreachable;
        }

        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            if (utils.optional(self.ptr())) |pointer|
                allocator.destroy(pointer);
        }
    };
}

pub fn Object(Type: type) type {
    return packed struct {
        const Self = @This();

        const Ptr = Pointer(Type);

        _ptr: Ptr,
        _own: bool,

        pub fn create(allocator: std.mem.Allocator) !Self {
            var self = Self.init(try allocator.create(Ptr.Val));
            if (utils.fn_error(Ptr.Val.init)) |_|
                self._ptr.set(try Ptr.Val.init(allocator))
            else
                self._ptr.set(Ptr.Val.init(allocator));

            self._own = true;
            return self;
        }

        pub fn init(arg: Type) Self {
            return Self{
                ._ptr = Ptr.init(arg),
                ._own = false,
            };
        }

        pub fn own(self: Self) bool {
            return self._own;
        }

        pub fn ptr(self: Self) Type {
            return self._ptr.ptr();
        }

        pub fn get(self: Self) Ptr.Opt {
            return self._ptr.get();
        }

        pub fn set(self: Self, val: Ptr.Val) if (Ptr.optional) Error.NullPointer!void else void {
            self._ptr.set(val);
        }

        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            if (self._own)
                self._ptr.ptr().deinit();
            self._ptr.destroy(allocator);
        }
    };
}

pub fn Slice(Type: type) type {
    return packed struct {
        const Self = @This();
        const Ptr = Pointer(utils.with_size(Type, .many));

        _ptr: Ptr,
        _len: usize,

        pub fn create(allocator: std.mem.Allocator, count: usize) !Self {
            return Self.init(try allocator.alloc(Ptr.Val, count));
        }

        pub fn init(arg: Type) Self {
            return Self{
                ._ptr = Ptr.init(arg.ptr),
                ._len = if (utils.optional(arg)) |val|
                    val.len
                else
                    0,
            };
        }

        pub fn ptr(self: Self) Type {
            return if (utils.optional(self._ptr.ptr())) |pointer|
                pointer[0..self._len]
            else if (Ptr.optional)
                null
            else
                unreachable;
        }

        pub fn get(self: Self, idx: usize) Ptr.Opt {
            return if (utils.optional(self.ptr())) |pointer|
                pointer[idx]
            else
                null;
        }

        pub fn len(self: Self) usize {
            return self._len;
        }

        pub fn set(self: Self, val: Ptr.Val) if (Ptr.optional) Error.NullPointer!void else void {
            if (utils.optional(self.ptr())) |pointer|
                @memcpy(pointer, val)
            else if (Ptr.optional)
                return Error.NullPointer
            else
                unreachable;
        }

        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            if (utils.optional(self.ptr())) |pointer|
                allocator.free(pointer);
        }
    };
}

pub fn Packed(Type: type) type {
    const Ptr = if (utils.is_type(Type, "optional")) @typeInfo(Type).optional.child else Type;
    const Child = @typeInfo(Ptr).pointer.child;

    return if (@typeInfo(Ptr).pointer.size == .slice)
        Slice(Type)
    else if ((utils.is_type(Child, "union") or
        utils.is_type(Child, "enum") or
        utils.is_type(Child, "struct")) and
        @hasDecl(Child, "init") and
        @hasDecl(Child, "deinit"))
        Object(Type)
    else
        Pointer(Type);
}
