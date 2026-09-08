const std = @import("std");

const table = @import("lib::table.zig");
const list = @import("lib::list.zig");
const utils = @import("lib::utils.zig");
const callbacks = @import("vm::callbacks.zig");
const native = @import("vm::native.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const hash = @import("hash.zig");

const OP = @import("op.zig").OP;
const Value = @import("value.zig").Value;
const GC = @import("gc.zig").GC;
const Obj = GC.Obj;
const Chunk = Obj.Chunk;

const InterpreterError = Obj.Error || compiler.CompilerError || callbacks.Error || error{ CompileError, RuntimeError, StackOverflow, IndexOutOfBounds, Overflow, DivisionByZero };

pub const VM = struct {
    objects: GC,
    globals: Globals,
    allocator: std.mem.Allocator,
    initializer: *Obj.String,

    pub const CALLSTACK = 64;
    pub const STACK = 256;
    pub const Compiler = compiler.Compiler(STACK);

    pub const Global = struct {
        val: Value,
        con: bool,

        const Self = @This();

        pub fn is_var(g: Self) bool {
            return !g.con;
        }

        pub fn make_var(v: Value) Self {
            return Self{
                .val = v,
                .con = false,
            };
        }

        pub fn make_con(v: Value) Self {
            return Self{
                .val = v,
                .con = true,
            };
        }
    };

    const Globals = table.Table(*Obj.String, Global, hash.hash_t(*Obj.String), Obj.String.eql);

    const CallFrame = struct {
        callee: *Obj.Function,
        ip: [*]const u8,
        slots: [*]Value,
        chunk: *const Chunk,

        pub fn init(callee: *Obj.Function, slots: [*]Value) @This() {
            return @This(){
                .callee = callee,
                .ip = callee.chunk.ptr().code.ptr().data.ptr,
                .chunk = callee.chunk.ptr(),
                .slots = slots,
            };
        }
    };

    fn defineNative(self: *@This(), name: []const u8, arity_min: u8, arity_max: u8, fun: Obj.Native.Fn) !void {
        const nameObj = try self.objects.emplace(.String, &.{name});
        GC.exclude(nameObj.cast());

        const funObj = try self.objects.emplace_cast(.Native, Obj.Native.Arg{
            .fun = fun,
            .arity_min = arity_min,
            .arity_max = arity_max,
        });
        GC.exclude(funObj);
        _ = try self.globals.set(nameObj, Global.make_con(Value.init(funObj)));
    }

    fn gc_callback(self_ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(self_ptr));

        self.globals.for_each(self, struct {
            pub fn fun(this: @TypeOf(self), name: *Obj.String, val: Global) void {
                this.objects.mark("G", name);
                this.objects.mark("G", val.val);
            }
        }.fun);
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !@This() {
        var self = @This(){
            .globals = Globals.init(allocator),
            .objects = try GC.init(allocator, io),
            .allocator = allocator,
            .initializer = undefined,
        };

        self.initializer = try self.objects.emplace(.String, &.{"init"});

        GC.exclude(self.initializer.cast());

        try self.defineNative("clock", 0, 0, native.Clock.clock);
        try self.defineNative("put", 1, 1, native.put);
        try self.defineNative("typeof", 1, 1, native.typeof);
        try self.defineNative("table", 0, Obj.Native.ArityMax, native.table);
        try self.defineNative("list", 0, Obj.Native.ArityMax, native.list);
        try self.defineNative("rungc", 0, 0, native.rungc);
        try self.defineNative("len", 1, 1, native.len);

        native.Clock.set_start(io);

        return self;
    }

    pub fn interpret(self: *@This(), source: []const u8, dbg: bool) InterpreterError!void {
        try self.objects.push_callback(&VM.gc_callback, self);
        defer self.objects.pop_callback();

        const chunk = try Compiler.compile(source, &self.objects);

        if (dbg) try debug.disassembleChunk(chunk);

        try Interpreter(CALLSTACK, Compiler.Stack).run(self, chunk, dbg);
    }

    fn Interpreter(callstack_size: comptime_int, stack_size: comptime_int) type {
        return struct {
            const List = list.List(*Obj.Upvalue);
            const Self = @This();

            frames: [callstack_size]CallFrame,
            frameCount: usize,
            stackTop: [*]Value,
            stack: [stack_size]Value,
            vm: *VM,
            upvalues: List,

            pub fn run(vm: *VM, chunk: *Obj.Chunk, dbg: bool) InterpreterError!void {
                var self = @This(){
                    .frames = @splat(undefined),
                    .frameCount = 0,
                    .stack = @splat(Value.init({})),
                    .stackTop = undefined,
                    .vm = vm,
                    .upvalues = List.init(vm.allocator),
                };
                self.stackTop = &self.stack;

                try vm.objects.push_callback(&Self.gc_callback, &self);
                defer vm.objects.pop_callback();

                defer self.upvalues.deinit();

                self.push(Value.init(chunk.cast()));

                const function = try vm.objects.emplace(.Function, .{ .type = .Script, .chunk = chunk });
                _ = self.pop();
                self.push(Value.init(function.cast()));

                try self.callFunction(function, 0);
                try self.execute(dbg);
            }

            pub fn gc_callback(self_ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(self_ptr));

                var stack_ptr: [*]Value = &self.stack;
                while (stack_ptr != self.stackTop) : (stack_ptr += 1) {
                    self.vm.objects.mark("S", stack_ptr[0]);
                }

                var frame_idx: usize = 0;
                while (frame_idx < self.frameCount) : (frame_idx += 1) {
                    self.vm.objects.mark("F", self.frames[frame_idx].callee);
                }

                var iter = self.upvalues.iter();
                while (iter.next()) |upval| {
                    self.vm.objects.mark("U", upval);
                }
            }

            fn frame(self: anytype) utils.copy_const(@TypeOf(self), *CallFrame) {
                return &self.frames[self.frameCount - 1];
            }

            fn ip(self: *const @This()) [*]const u8 {
                return self.frame().ip;
            }

            fn ip_add(self: *@This(), adv: usize) void {
                self.frame().ip += adv;
            }

            fn ip_sub(self: *@This(), adv: usize) void {
                self.frame().ip -= adv;
            }

            fn read_byte(self: *@This()) u8 {
                const out: u8 = self.ip()[0];
                self.ip_add(1);
                return out;
            }

            fn read_short(self: *@This()) u16 {
                const msb: u16 = self.read_byte();
                const lsb: u16 = self.read_byte();
                return (msb << 8) | lsb;
            }

            fn read_constant(self: *@This()) Value {
                return self.frame().chunk.constants.ptr().get(self.read_byte()).?;
            }

            fn read_string(self: *@This()) *Obj.String {
                return self.read_constant().obj.cast(.String) catch unreachable;
            }

            fn push(self: *@This(), val: Value) void {
                self.stackTop[0] = val;
                self.stackTop += 1;
            }

            fn pop(self: *@This()) Value {
                self.stackTop -= 1;
                return self.stackTop[0];
            }

            fn peek(self: *@This(), distance: usize) Value {
                return (self.stackTop - (1 + distance))[0];
            }

            fn pook(self: *@This(), distance: usize, val: Value) void {
                (self.stackTop - (1 + distance))[0] = val;
            }

            fn callValue(self: *@This(), callee: Value, argCount: u8) !void {
                if (callee.cast_if(Obj.Type.Function)) |fun| {
                    try self.callFunction(fun, argCount);
                } else if (callee.cast_if(Obj.Type.Native)) |nat| {
                    try self.callNative(nat, argCount);
                } else if (callee.cast_if(Obj.Type.Class)) |cls| {
                    try self.callClass(cls, argCount);
                } else {
                    self.runtimeError("Can only call functions and classes", .{});
                    return InterpreterError.RuntimeError;
                }
            }

            fn callClass(self: *@This(), callee: *Obj.Class, argCount: u8) !void {
                const instance = try self.vm.objects.emplace(.Instance, callee);

                const initializer = instance.method(&self.vm.objects, self.vm.initializer) catch
                    if (argCount != 0) {
                        self.runtimeError("Expected 0 arguments but got {d}", .{argCount});
                        return InterpreterError.RuntimeError;
                    } else {
                        self.pook(argCount, Value.init(instance.cast()));
                        return;
                    };

                try self.callFunction(initializer, argCount);
            }

            fn callFunction(self: *@This(), callee: *Obj.Function, argCount: u8) !void {
                if (argCount != callee.arity) {
                    self.runtimeError("Expected {d} arguments but got {d}", .{ callee.arity, argCount });
                    return InterpreterError.RuntimeError;
                }
                if (self.frameCount == callstack_size - 1)
                    return InterpreterError.StackOverflow;
                self.frameCount += 1;
                self.frames[self.frameCount - 1] = CallFrame.init(callee, self.stackTop - argCount - 1);
            }

            fn callNative(self: *@This(), obj: *Obj.Native, argCount: u8) !void {
                if (argCount < obj.arity_min or argCount > obj.arity_max) {
                    self.runtimeError("Expected from {d} to {d} arguments but got {d}", .{ obj.arity_min, obj.arity_max, argCount });
                    return InterpreterError.RuntimeError;
                }
                const result = try obj.call(&self.vm.objects, argCount, self.stackTop - argCount);
                self.stackTop -= argCount + 1;
                self.push(result);
                return;
            }

            fn captureUpvalue(self: *@This(), slot: u8) !*Obj.Upvalue {
                var iter = self.upvalues.iter();

                while (iter.next()) |val| {
                    if (val.slot == slot)
                        return val;
                    if (val.slot > slot)
                        break;
                }
                _ = iter.next();

                const new = try self.vm.objects.emplace(.Upvalue, .{ .val = &self.frame().slots[slot], .slot = slot });
                try iter.push(new);
                return new;
            }

            fn closeUpvalues(self: *@This(), slot: u8) !void {
                var iter = self.upvalues.iter();

                while (iter.next()) |upval| {
                    if (upval.slot < slot) break;

                    try upval.close(self.vm.allocator);
                    iter.pop();
                }
            }

            fn binary_op(self: *@This(), comptime in_tag: anytype, comptime out_tag: anytype, op: callbacks.Type(in_tag, out_tag)) InterpreterError!void {
                const b = self.peek(0);
                const a = self.peek(1);
                if (a.is(in_tag) and b.is(in_tag)) {
                    const val = Value.init(try op.call(a.get(in_tag), b.get(in_tag)));
                    _ = self.pop();
                    _ = self.pop();
                    self.push(val);
                } else {
                    self.runtimeError("Operands have invalid types, expected: {s}", .{@tagName(in_tag)});
                    return InterpreterError.RuntimeError;
                }
            }

            fn instruction_idx(self: *const @This()) usize {
                return @intFromPtr(self.ip()) - @intFromPtr(self.frame().chunk.code.ptr().data.ptr);
            }

            fn current_slot(self: *const @This()) u8 {
                return @intCast((@intFromPtr(self.stackTop) - @intFromPtr(self.frame().slots)) / @sizeOf(@TypeOf(self.stackTop[0])));
            }

            fn execute(self: *@This(), dbg: bool) !void {
                while (true) {
                    if (dbg) {
                        std.debug.print("          ", .{});
                        var stackPtr: [*]Value = &self.stack;
                        while (stackPtr != self.stackTop) : (stackPtr += 1) {
                            std.debug.print("[{f}]", .{stackPtr[0]});
                        }
                        std.debug.print("\n", .{});
                        _ = try debug.disassembleInstruction(self.frame().chunk, self.instruction_idx());
                    }
                    const instruction: u8 = self.read_byte();
                    switch (instruction) {
                        @intFromEnum(OP.PRINT) => {
                            std.debug.print("{f}\n", .{self.pop()});
                        },
                        @intFromEnum(OP.RETURN) => {
                            const result = self.pop();
                            if (self.frameCount == 1) {
                                _ = self.pop();
                                return;
                            }
                            try self.closeUpvalues(0);
                            self.stackTop = self.frame().slots;
                            self.frameCount -= 1;
                            self.push(result);
                        },
                        @intFromEnum(OP.POP) => _ = self.pop(),
                        @intFromEnum(OP.CONSTANT) => self.push(self.read_constant()),
                        @intFromEnum(OP.NEGATE) => {
                            if (!self.peek(0).is(Value.number)) {
                                self.runtimeError("Operand must be a number.", .{});
                                return InterpreterError.RuntimeError;
                            }
                            self.push(Value.init(-self.pop().number));
                        },
                        @intFromEnum(OP.ADD) => {
                            if (self.peek(0).is(Obj.Type.String)) {
                                try self.binary_op(Obj.Type.String, Obj.Type.String, callbacks.concatenate(&self.vm.objects));
                            } else {
                                try self.binary_op(Value.number, Value.number, callbacks.add);
                            }
                        },
                        @intFromEnum(OP.JUMP_IF_FALSE) => {
                            const offset = self.read_short();
                            if (!self.peek(0).isTruthy()) {
                                self.ip_add(offset);
                            }
                        },
                        @intFromEnum(OP.JUMP) => {
                            self.ip_add(self.read_short());
                        },
                        @intFromEnum(OP.JUMP_POP) => {
                            self.ip_add(@intFromFloat(self.pop().number));
                        },
                        @intFromEnum(OP.LOOP) => {
                            self.ip_sub(self.read_short());
                        },
                        @intFromEnum(OP.GET_LOCAL) => {
                            self.push(self.frame().slots[self.read_byte()]);
                        },
                        @intFromEnum(OP.SET_LOCAL) => {
                            self.frame().slots[self.read_byte()] = self.peek(0);
                        },
                        @intFromEnum(OP.GET_PROPERTY) => {
                            var val = self.peek(0);
                            if (val.cast_if(Obj.Type.Instance)) |instance| {
                                const field = self.read_string();
                                const prop = instance.fields.ptr().get(field) catch
                                    Value.init((instance.method(&self.vm.objects, field) catch {
                                        self.runtimeError("Undefined property '{f}'", .{field});
                                        return InterpreterError.RuntimeError;
                                    }).cast());
                                _ = self.pop();
                                self.push(prop);
                            } else {
                                self.runtimeError("Only instances have properties, found: {s}", .{self.peek(0).typeName()});
                                return InterpreterError.RuntimeError;
                            }
                        },
                        @intFromEnum(OP.SET_PROPERTY) => {
                            if (self.peek(1).cast_if(Obj.Type.Instance)) |instance| {
                                _ = try instance.fields.ptr().set(self.read_string(), self.peek(0));
                                const val = self.pop();
                                _ = self.pop();
                                self.push(val);
                            } else {
                                self.runtimeError("Only instances have properties, found: {s}", .{self.peek(0).typeName()});
                                return InterpreterError.RuntimeError;
                            }
                        },
                        @intFromEnum(OP.GET_GLOBAL) => {
                            const name = self.read_string();
                            const global = self.vm.globals.get(name) catch {
                                self.runtimeError("Undefined variable: '{s}'", .{name.slice()});
                                return InterpreterError.RuntimeError;
                            };
                            self.push(global.val);
                        },
                        @intFromEnum(OP.SET_GLOBAL) => {
                            const name = self.read_string();
                            const replaced = self.vm.globals.replace_if(name, Global.make_var(self.peek(0)), Global.is_var) catch {
                                self.runtimeError("Undefined variable: '{s}'", .{name.slice()});
                                return InterpreterError.RuntimeError;
                            };
                            if (!replaced) {
                                self.runtimeError("Cannot assign to a constant: '{s}'", .{name.slice()});
                                return InterpreterError.RuntimeError;
                            }
                        },
                        @intFromEnum(OP.GET_UPVALUE) => {
                            const closure = self.frame().callee;
                            const index = self.read_byte();
                            self.push(closure.upvalues.get(index).?.location.get());
                        },
                        @intFromEnum(OP.SET_UPVALUE) => {
                            const closure = self.frame().callee;
                            const index = self.read_byte();
                            closure.upvalues.get(index).?.location.set(self.peek(0));
                        },
                        @intFromEnum(OP.CLOSE_UPVALUE) => {
                            try self.closeUpvalues(self.current_slot());
                            _ = self.pop();
                        },
                        @intFromEnum(OP.GET_INDEX) => {
                            const key = self.pop();
                            const col = self.pop();
                            var pushed = false;

                            if (col.cast_if(Value.obj)) |obj| {
                                switch (obj.type) {
                                    inline .Table, .String, .List => |tp| {
                                        self.push((obj.cast(tp) catch unreachable).get(key) catch Value.init({}));
                                        pushed = true;
                                    },
                                    else => {},
                                }
                            }

                            if (!pushed) {
                                self.runtimeError("Cannot index a value of type {s}", .{col.typeName()});
                                return InterpreterError.RuntimeError;
                            }
                        },
                        @intFromEnum(OP.SET_INDEX) => {
                            const val = self.pop();
                            const key = self.pop();
                            const col = self.pop();
                            var pushed = false;

                            if (col.cast_if(Value.obj)) |obj| {
                                switch (obj.type) {
                                    inline .Table, .List => |tp| {
                                        var m = obj.cast(tp) catch unreachable;
                                        if (val.is(Value.nil)) {
                                            m.delete(key);
                                        } else {
                                            _ = try m.set(key, val);
                                        }
                                        pushed = true;
                                    },
                                    else => {},
                                }
                            }
                            if (!pushed) {
                                self.runtimeError("Cannot index a value of type {s}", .{col.typeName()});
                                return InterpreterError.RuntimeError;
                            }
                            self.push(val);
                        },
                        @intFromEnum(OP.CALL) => {
                            const argCount = self.read_byte();
                            try self.callValue(self.peek(argCount), argCount);
                        },
                        @intFromEnum(OP.CLOSURE) => {
                            const chunk = try self.read_constant().obj.cast(.Chunk);
                            const arity = self.read_byte();
                            const count = self.read_byte();

                            const closure = try self.vm.objects.emplace(.Function, .{
                                .type = .Closure,
                                .chunk = chunk,
                                .arity = arity,
                                .upvalues = count,
                            });

                            self.push(Value.init(closure.cast()));

                            for (closure.upvalues.ptr()) |*upvalue| {
                                const tp = self.read_byte();
                                const slot = self.read_byte();
                                const U = Compiler.Upvalue.Type;
                                upvalue.* = switch (tp) {
                                    @intFromEnum(U.local) => try self.captureUpvalue(slot),
                                    @intFromEnum(U.remote) => self.frame().callee.upvalues.get(slot),
                                    else => return InterpreterError.RuntimeError,
                                };
                            }
                        },
                        @intFromEnum(OP.METHOD) => {
                            const name = self.read_string();
                            const method = try self.pop().obj.cast(.Function);
                            const class = try self.peek(0).obj.cast(.Class);
                            _ = try class.methods.ptr().set(name, method);
                        },
                        @intFromEnum(OP.DEFINE_GLOBAL) => _ = try self.vm.globals.set(self.read_string(), Global.make_var(self.pop())),
                        @intFromEnum(OP.DEFINE_GLOBAL_CONSTANT) => _ = try self.vm.globals.set(self.read_string(), Global.make_con(self.pop())),
                        @intFromEnum(OP.SUBTRACT) => try self.binary_op(Value.number, Value.number, callbacks.sub),
                        @intFromEnum(OP.MULTIPLY) => try self.binary_op(Value.number, Value.number, callbacks.mul),
                        @intFromEnum(OP.DIVIDE) => try self.binary_op(Value.number, Value.number, callbacks.div),
                        @intFromEnum(OP.TRUE) => self.push(Value.init(true)),
                        @intFromEnum(OP.FALSE) => self.push(Value.init(false)),
                        @intFromEnum(OP.EQUAL) => self.push(Value.init(self.pop().eql(self.pop()))),
                        @intFromEnum(OP.LESS) => try self.binary_op(Value.number, Value.bool, callbacks.less),
                        @intFromEnum(OP.GREATER) => try self.binary_op(Value.number, Value.bool, callbacks.more),
                        @intFromEnum(OP.NIL) => self.push(Value.init({})),
                        @intFromEnum(OP.NOT) => self.push(Value.init(!self.pop().isTruthy())),
                        else => return InterpreterError.CompileError,
                    }
                }
            }

            fn runtimeError(self: *@This(), comptime fmt: []const u8, args: anytype) void {
                var i = self.frameCount - 1;
                while (true) : (i -= 1) {
                    const fram = self.frames[i];
                    const idx = @intFromPtr(fram.ip) - @intFromPtr(fram.chunk.code.ptr().data.ptr);
                    std.debug.print("[line {d}] in {f}\n", .{ fram.chunk.lines.ptr().get(idx) orelse 1, fram.callee });
                    if (i == 0) break;
                }
                std.debug.print(fmt ++ "\n", args);
            }
        };
    }

    pub fn deinit(self: *@This()) void {
        self.objects.deinit();
        self.globals.deinit();
    }
};
