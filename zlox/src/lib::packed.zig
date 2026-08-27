const std = @import("std");

const utils = @import("lib::utils.zig");

pub fn Packed(Type: type) type {
    return packed struct {
        const optional = utils.is_type(Type, "optional");

        const Ptr = if (optional) @typeInfo(Type).optional.child else Type;

        const Child = if (utils.is_type(Ptr, "pointer"))
            @typeInfo(Ptr).pointer.child
        else
            @compileError("Expected pointer type, got " ++ @typeName(Ptr));

        const slice = @typeInfo(Ptr).pointer.size == .slice;
        const many = @typeInfo(Ptr).pointer.size == .many;

        const Self = @This();

        _ptr: usize,
        _len: if (slice) usize else void,

        pub fn create(allocator: std.mem.Allocator) !Self {
            return if (slice or many)
                @compileError("Cannot create() a slice or many pointer, use alloc() instead")
            else
                Self.init(try allocator.create(Child));
        }

        pub fn alloc(allocator: std.mem.Allocator, count: usize) !Self {
            return if (slice)
                Self.init(try allocator.alloc(Child, count))
            else if (many)
                Self.init((try allocator.alloc(Child, count)).ptr)
            else if (count == 1)
                Self.create(allocator)
            else
                @panic("Cannot alloc() a single-item pointer with a count of more than one");
        }

        pub fn init(arg: Type) Self {
            return Self{
                ._ptr = if (optional)
                    if (arg) |val|
                        @intFromPtr(if (slice) val.ptr else val)
                    else
                        0
                else
                    @intFromPtr(if (slice) arg.ptr else arg),

                ._len = if (slice)
                    if (optional)
                        if (arg) |val|
                            val.len
                        else
                            0
                    else
                        arg.len,
            };
        }

        pub fn ptr(self: Self) Type {
            return if (optional and self._ptr == 0)
                null
            else if (slice)
                @as(utils.with_size(Ptr, .many), @ptrFromInt(self._ptr))[0..self._len]
            else
                @ptrFromInt(self._ptr);
        }

        pub fn get(self: Self) if (optional) ?Child else Child {
            return if (slice or many)
                @compileError("Cannot call get() on a slice or many pointer")
            else if (optional and self._ptr == 0)
                null
            else
                @as(Ptr, @ptrFromInt(self._ptr)).*;
        }

        pub fn at(self: Self, idx: usize) if (optional) ?Child else Child {
            return if (!slice and !many)
                @compileError("Cannot call at() on a single-item pointer")
            else if (optional and self._ptr == 0)
                null
            else
                self.ptr()[idx];
        }

        pub fn len(self: Self) usize {
            return if (slice)
                self._len
            else
                @compileError("Cannot call len() on a non-slice pointer");
        }

        pub fn free(self: Self, allocator: std.mem.Allocator, count: usize) void {
            const pointer = if (optional)
                if (self.ptr()) |_ptr|
                    _ptr
                else
                    return
            else
                self.ptr();

            if (many) {
                allocator.free(pointer[0..count]);
            } else if (slice) {
                if (count != self._len)
                    @panic("Count has to be equal to the length of the slice");

                allocator.free(pointer);
            } else {
                if (count != 1)
                    @panic("Count has to be equal 1 for a single-item pointer");

                allocator.destroy(pointer);
            }
        }

        pub fn set(self: Self, val: if (many or slice) utils.mod_ptr_t(Ptr, "const", true) else Child) void {
            if (many or slice)
                @memcpy(self.ptr(), val)
            else
                self.ptr().* = val;
        }

        pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
            if (many)
                @compileError("Cannot use destroy() on a many-pointer, call free() instead");

            self.free(allocator, if (slice) self._len else 1);
        }
    };
}
