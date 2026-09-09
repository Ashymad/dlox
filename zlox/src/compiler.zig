const std = @import("std");

const vm_native = @import("vm::native.zig");
const utils = @import("lib::utils.zig");
const scanner = @import("scanner.zig");
const debug = @import("debug.zig");
const value = @import("value.zig");

const Token = scanner.TokenType;
const OP = @import("op.zig").OP;
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Obj = GC.Obj;
const Chunk = Obj.Chunk;

pub const CompilerError = Obj.Error || scanner.ScannerError || Chunk.Error || Value.ParseNumberError || error{ UnexpectedToken, NotAnExpression };

const Precedence = enum {
    NONE,
    ASSIGNMENT, // =
    TERNARY, // ? :
    OR, // or
    AND, // and
    EQUALITY, // == !=
    COMPARISON, // < > <= >=
    TERM, // + -
    FACTOR, // * /
    UNARY, // ! -
    CALL, // . () []
    PRIMARY,

    pub fn inc(self: @This()) @This() {
        return @enumFromInt(@intFromEnum(self) + 1);
    }

    pub fn lessOrEq(self: @This(), rhs: @This()) bool {
        return @intFromEnum(self) <= @intFromEnum(rhs);
    }
};

pub fn Compiler(size: comptime_int) type {
    return struct {
        current: scanner.Token,
        previous: scanner.Token,
        scanner: *scanner.Scanner,
        lastError: CompilerError,
        hadError: bool,
        panicMode: bool,
        chunk: *Obj.Chunk,
        initializer: bool,
        objects: *GC,
        locals: [size]Local,
        localCount: usize,
        scopeDepth: usize,
        enclosing: ?*Self,
        upvalues: [upvalues_size]Upvalue,
        upvaluesCount: u8,
        currentClass: ?*Class,

        const Class = struct {
            enclosing: ?*Class,
        };

        const Self = @This();
        pub const Stack = size;

        pub const Upvalue = struct {
            pub const Type = enum(u8) { local = 0, remote = 1 };

            index: u8,
            type: Type,
        };

        const upvalues_size = std.math.maxInt(u8);

        const Local = struct {
            name: scanner.Token = scanner.Token.Empty,
            depth: ?usize = null,
            con: bool = true,
            captured: bool = false,
        };

        const ParseFn = *const fn (*Self, bool) void;

        const ParseRule = struct {
            prefix: ?ParseFn,
            infix: ?ParseFn,
            precedence: Precedence,
            pub fn init(prefix: ?ParseFn, infix: ?ParseFn, precedence: Precedence) @This() {
                return @This(){ .prefix = prefix, .infix = infix, .precedence = precedence };
            }
        };

        const rules = init: {
            var new: [utils.enum_len(Token)]ParseRule = undefined;
            for (&new, 0..) |*v, i| {
                const T = Token;
                const S = Self;
                const R = ParseRule.init;
                const P = Precedence;
                const tok: Token = @enumFromInt(i);
                v.* = switch (tok) {
                    // zig fmt: off
                    T.LEFT_PAREN    => R(S.grouping, S.call,    P.CALL ),
                    T.LEFT_BRACKET  => R(S.listTable,S.index,   P.CALL ),
                    T.MINUS         => R(S.unary,    S.binary,  P.TERM ),
                    T.PLUS          => R(null,       S.binary,  P.TERM ),
                    T.SLASH         => R(null,       S.binary,  P.FACTOR ),
                    T.STAR          => R(null,       S.binary,  P.FACTOR ),
                    T.QUESTION      => R(null,       S.ternary, P.TERNARY ),
                    T.BANG          => R(S.unary,    null,      P.NONE ),
                    T.BANG_EQUAL    => R(null,       S.binary,  P.EQUALITY ),
                    T.EQUAL_EQUAL   => R(null,       S.binary,  P.EQUALITY ),
                    T.GREATER       => R(null,       S.binary,  P.COMPARISON ),
                    T.GREATER_EQUAL => R(null,       S.binary,  P.COMPARISON ),
                    T.LESS          => R(null,       S.binary,  P.COMPARISON ),
                    T.LESS_EQUAL    => R(null,       S.binary,  P.COMPARISON ),
                    T.IDENTIFIER    => R(S.variable, null,      P.NONE ),
                    T.STRING        => R(S.string,   null,      P.NONE ),
                    T.CHAR          => R(S.char,     null,      P.NONE ),
                    T.NUMBER        => R(S.number,   null,      P.NONE ),
                    T.AND           => R(null,       S._and,    P.AND ),
                    T.FALSE         => R(S.literal,  null,      P.NONE ),
                    T.NIL           => R(S.literal,  null,      P.NONE ),
                    T.OR            => R(null,       S._or,     P.OR ),
                    T.TRUE          => R(S.literal,  null,      P.NONE ),
                    T.FUN           => R(S.funExpression, null,      P.NONE ),
                    T.CLASS         => R(S.class,    null,      P.NONE ),
                    T.DOT           => R(null,       S.dot,     P.CALL ),
                    T.THIS          => R(S.this,     null,      P.NONE ),
                    else            => R(null,       null,      P.NONE ),
                    // zig fmt: on
                };
            }
            break :init new;
        };

        fn getRule(tok: Token) *const ParseRule {
            return &Self.rules[@intFromEnum(tok)];
        }

        fn advance(self: *Self) void {
            self.previous = self.current;

            while (true) {
                self.current = self.scanner.scanToken();

                if (self.current.type) |_| {
                    break;
                } else |err| {
                    self.lastError = err;
                    self.errorAtCurrent(scanner.ScannerErrorString(err));
                }
            }
        }

        fn emitByte(self: *Self, byte: u8) void {
            self.chunk.write(byte, self.previous.line) catch |err| {
                self.lastError = err;
                self.errorAtCurrent("Out of Memory");
            };
        }

        fn emitOP(self: *Self, op: OP) void {
            self.chunk.writeOP(op, self.previous.line) catch |err| {
                self.lastError = err;
                self.errorAtCurrent("Out of Memory");
            };
        }

        fn emit(self: *Self, op: OP, byte: u8) void {
            self.emitOP(op);
            self.emitByte(byte);
        }

        fn emit2OP(self: *Self, op: OP, op2: OP) void {
            self.emitOP(op);
            self.emitOP(op2);
        }

        fn end(self: *Self) !*Obj.Chunk {
            self.emitReturn();
            return self.chunk;
        }

        fn emitReturn(self: *Self) void {
            if (self.initializer)
                self.emit(OP.GET_LOCAL, 0)
            else if (self.enclosing) |_|
                self.emitOP(OP.NIL);

            self.emitOP(OP.RETURN);
        }

        fn errorAtCurrent(self: *Self, message: []const u8) void {
            self.errorAt(self.current, message);
        }

        fn errorAtPrevious(self: *Self, message: []const u8) void {
            self.errorAt(self.previous, message);
        }

        fn expression(self: *Self) void {
            self.parsePrecedence(Precedence.ASSIGNMENT);
        }

        fn parsePrecedence(self: *Self, precedence: Precedence) void {
            const canAssign = precedence.lessOrEq(Precedence.ASSIGNMENT);

            self.advance();
            if (getRule(self.previous.type catch return).prefix) |prefixRule| {
                prefixRule(self, canAssign);
            } else {
                self.lastError = CompilerError.NotAnExpression;
                self.errorAtPrevious("Expect expression.");
                return;
            }

            while (precedence.lessOrEq(getRule(self.current.type catch unreachable).precedence)) {
                self.advance();
                if (getRule(self.previous.type catch unreachable).infix) |infixRule| {
                    infixRule(self, canAssign);
                } else {
                    self.lastError = CompilerError.NotAnExpression;
                    self.errorAtPrevious("Expect expression.");
                    return;
                }
            }

            if (canAssign and self.match(Token.EQUAL)) {
                self.errorAtPrevious("Invalid assignment target.");
            }
        }

        fn errorAt(self: *Self, token: scanner.Token, message: []const u8) void {
            if (self.panicMode) return;
            self.panicMode = true;
            std.debug.print("[{d}:{d}] Error", .{ token.line, token.column });
            if (token.type) |tpe| {
                if (tpe == Token.EOF) {
                    std.debug.print(" at end", .{});
                } else {
                    std.debug.print(" at {s}", .{token.lexeme});
                }
            } else |_| {}
            std.debug.print(": {s}\n", .{message});
            self.hadError = true;
        }

        fn consume(self: *Self, tok: Token, message: []const u8) void {
            if (self.current.type) |tpe| {
                if (tpe == tok) {
                    self.advance();
                    return;
                }
            } else |_| {}
            self.lastError = CompilerError.UnexpectedToken;
            self.errorAtCurrent(message);
        }

        fn number(self: *Self, _: bool) void {
            self.emitConstant(Value.parseNumber(self.previous.lexeme) catch |err| {
                self.lastError = err;
                self.errorAtPrevious("Invalid numeric literal");
                return;
            });
        }

        fn string(self: *Self, _: bool) void {
            self.emitObj(.String, &.{self.previous.lexeme[1 .. self.previous.lexeme.len - 1]}) catch return;
        }

        fn char(self: *Self, _: bool) void {
            self.emitConstant(Value.init(self.previous.lexeme[1]));
        }

        fn call(self: *Self, _: bool) void {
            const argCount = self.argumentList();
            self.emit(OP.CALL, argCount);
        }

        fn dot(self: *Self, canAssign: bool) void {
            self.consume(Token.IDENTIFIER, "Expect property name after '.'");
            const name = self.identifierConstant(self.previous) catch return;

            if (canAssign and self.match(Token.EQUAL)) {
                self.expression();
                self.emit(OP.SET_PROPERTY, name);
            } else {
                self.emit(OP.GET_PROPERTY, name);
            }
        }

        fn argumentList(self: *Self) u8 {
            var argCount: u8 = 0;
            if (!self.check(Token.RIGHT_PAREN)) {
                while (true) {
                    self.expression();
                    if (argCount == std.math.maxInt(u8)) {
                        self.errorAtPrevious("Too many arguments");
                        return argCount;
                    }
                    argCount += 1;
                    if (!self.match(Token.COMMA)) break;
                }
            }
            self.consume(Token.RIGHT_PAREN, "Expect ')' after arguments");
            return argCount;
        }

        fn makeObj(self: *Self, comptime tp: Obj.Type, arg: tp.get().Arg) !u8 {
            return self.makeConstant(Value.init(self.objects.emplace_cast(tp, arg) catch |err| {
                self.lastError = err;
                self.errorAtPrevious("Unable to allocate obj");
                return err;
            }));
        }

        fn emitObj(self: *Self, comptime tp: Obj.Type, arg: tp.get().Arg) !void {
            self.emit(OP.CONSTANT, try self.makeObj(tp, arg));
        }

        fn listTable(self: *Self, _: bool) void {
            self.emit(OP.CONSTANT, 0xff);
            const offset = self.chunk.code.ptr().len - 1;
            var argCount: u8 = 0;
            var isList = true;

            if (self.match(Token.RIGHT_BRACKET)) {} else if (self.match(Token.COLON)) {
                isList = false;
                self.consume(Token.RIGHT_BRACKET, "Expect ']'");
            } else {
                self.expression();
                argCount += 1;
                if (self.match(Token.COLON)) {
                    isList = false;
                    self.expression();
                    argCount += 1;
                }
                while (!self.match(Token.RIGHT_BRACKET)) {
                    self.consume(Token.COMMA, "Expect ',' between expressions");
                    if (self.match(Token.RIGHT_BRACKET)) break;
                    self.expression();
                    argCount += 1;
                    if (!isList) {
                        self.consume(Token.COLON, "Expect ':' between key and value");
                        self.expression();
                        argCount += 1;
                    }
                }
            }
            if (isList) {
                self.chunk.code.ptr().set(offset, self.makeObj(.Native, .{
                    .fun = vm_native.list,
                }) catch return) catch return;
            } else {
                self.chunk.code.ptr().set(offset, self.makeObj(.Native, .{
                    .fun = vm_native.table,
                }) catch return) catch return;
            }
            self.emit(OP.CALL, argCount);
        }

        fn index(self: *Self, canAssign: bool) void {
            self.expression();
            self.consume(Token.RIGHT_BRACKET, "Expect ']' after index expression");
            if (canAssign and self.match(Token.EQUAL)) {
                self.expression();
                self.emitOP(OP.SET_INDEX);
            } else {
                self.emitOP(OP.GET_INDEX);
            }
        }

        fn this(self: *Self, _: bool) void {
            if (self.currentClass) |_| {
                self.variable(false);
            } else {
                self.errorAtPrevious("Can't use 'this' outside of class.");
            }
        }

        fn variable(self: *Self, canAssign: bool) void {
            self.namedVariable(self.previous, canAssign);
        }

        fn namedVariable(self: *Self, tok: scanner.Token, canAssign: bool) void {
            const OPs: struct { get: OP, set: OP, arg: u8 } = if (self.resolveLocal(tok)) |arg|
                .{ .get = OP.GET_LOCAL, .set = OP.SET_LOCAL, .arg = arg }
            else if (self.resolveUpvalue(tok)) |arg|
                .{ .get = OP.GET_UPVALUE, .set = OP.SET_UPVALUE, .arg = arg }
            else
                .{ .get = OP.GET_GLOBAL, .set = OP.SET_GLOBAL, .arg = self.identifierConstant(tok) catch return };

            if (canAssign and self.match(Token.EQUAL)) {
                if (OPs.get == OP.GET_LOCAL and self.locals[OPs.arg].con) {
                    self.errorAtPrevious("Cannot assign to a constant");
                    return;
                }
                self.expression();
                self.emit(OPs.set, OPs.arg);
            } else {
                self.emit(OPs.get, OPs.arg);
            }
        }

        fn resolveUpvalue(self: *Self, name: scanner.Token) ?u8 {
            if (self.enclosing) |enclosing| {
                if (enclosing.resolveLocal(name)) |local| {
                    enclosing.locals[local].captured = true;
                    return self.addUpvalue(local, .local) catch null;
                } else if (enclosing.resolveUpvalue(name)) |upvalue| {
                    return self.addUpvalue(upvalue, .remote) catch null;
                }
            }
            return null;
        }

        fn addUpvalue(self: *Self, idx: u8, tp: Upvalue.Type) !u8 {
            const count = self.upvaluesCount;

            for (self.upvalues[0..count], 0..) |upvalue, i| {
                if (upvalue.index == idx and upvalue.type == tp) {
                    return @intCast(i);
                }
            }

            if (count == upvalues_size) {
                self.errorAtPrevious("Too many upvalues");
                self.lastError = error.OutOfMemory;
                return self.lastError;
            }

            self.upvalues[count] = .{ .index = idx, .type = tp };
            self.upvaluesCount += 1;
            return count;
        }

        fn resolveLocal(self: *Self, name: scanner.Token) ?u8 {
            var i = self.localCount;
            while (i > 0) : (i -= 1) {
                if (identifiersEql(self.locals[i - 1].name, name)) {
                    if (self.locals[i - 1].depth) |_| {
                        return @intCast(i - 1);
                    } else {
                        self.errorAt(name, "Can't read local variable in it's own initializer");
                    }
                }
            }
            return null;
        }

        fn emitConstant(self: *Self, val: Value) void {
            self.emit(OP.CONSTANT, self.makeConstant(val));
        }

        fn makeConstant(self: *Self, val: Value) u8 {
            return self.chunk.addConstant(val) catch |err| {
                self.lastError = err;
                self.errorAtPrevious("Too many constants in one chunk");
                return 0;
            };
        }

        fn grouping(self: *Self, _: bool) void {
            self.expression();
            self.consume(Token.RIGHT_PAREN, "Expected ')' after expression");
        }

        fn _and(self: *Self, _: bool) void {
            const endJump = self.emitJump(OP.JUMP_IF_FALSE);

            self.emitOP(OP.POP);
            self.parsePrecedence(Precedence.AND);
            self.patchJump(endJump);
        }

        fn _or(self: *Self, _: bool) void {
            const elseJump = self.emitJump(OP.JUMP_IF_FALSE);
            const endJump = self.emitJump(OP.JUMP);

            self.patchJump(elseJump);
            self.emitOP(OP.POP);
            self.parsePrecedence(Precedence.OR);
            self.patchJump(endJump);
        }

        fn unary(self: *Self, _: bool) void {
            const operatorType = self.previous.type catch unreachable;

            self.parsePrecedence(Precedence.UNARY);

            switch (operatorType) {
                Token.MINUS => self.emitOP(OP.NEGATE),
                Token.BANG => self.emitOP(OP.NOT),
                else => unreachable,
            }
        }

        fn literal(self: *Self, _: bool) void {
            switch (self.previous.type catch unreachable) {
                Token.FALSE => self.emitOP(OP.FALSE),
                Token.TRUE => self.emitOP(OP.TRUE),
                Token.NIL => self.emitOP(OP.NIL),
                else => unreachable,
            }
        }

        fn binary(self: *Self, _: bool) void {
            const operatorType = self.previous.type catch unreachable;
            self.parsePrecedence(getRule(operatorType).precedence.inc());

            switch (operatorType) {
                Token.PLUS => self.emitOP(OP.ADD),
                Token.MINUS => self.emitOP(OP.SUBTRACT),
                Token.STAR => self.emitOP(OP.MULTIPLY),
                Token.SLASH => self.emitOP(OP.DIVIDE),
                Token.BANG_EQUAL => self.emit2OP(OP.EQUAL, OP.NOT),
                Token.EQUAL_EQUAL => self.emitOP(OP.EQUAL),
                Token.GREATER => self.emitOP(OP.GREATER),
                Token.GREATER_EQUAL => self.emit2OP(OP.LESS, OP.NOT),
                Token.LESS => self.emitOP(OP.LESS),
                Token.LESS_EQUAL => self.emit2OP(OP.GREATER, OP.NOT),
                else => unreachable,
            }
        }

        fn ternary(self: *Self, _: bool) void {
            const operatorType = self.previous.type catch unreachable;

            const thenJump = self.emitJump(OP.JUMP_IF_FALSE);
            self.emitOP(OP.POP);
            self.parsePrecedence(getRule(operatorType).precedence.inc());
            const elseJump = self.emitJump(OP.JUMP);
            self.patchJump(thenJump);

            self.consume(Token.COLON, "Expected ':' in ternary expression.");

            self.emitOP(OP.POP);
            self.parsePrecedence(getRule(operatorType).precedence.inc());
            self.patchJump(elseJump);
        }

        fn declaration(self: *Self) void {
            if (self.match(Token.CLASS)) {
                self.classDeclaration();
            } else if (self.match(Token.FUN)) {
                self.funDeclaration();
            } else if (self.match(Token.VAR)) {
                self.varDeclaration();
            } else if (self.match(Token.CON)) {
                self.conDeclaration();
            } else {
                self.statement();
            }

            if (self.panicMode) self.synchronize();
        }

        fn classDeclaration(self: *Self) void {
            const global = self.parseVariable("Expect class name.", true) catch return;
            self.markInitialized();
            self.class(false);
            self.defineVariable(global, true);
        }

        fn class(self: *Self, _: bool) void {
            const cls = self.objects.emplace_cast(Obj.Type.Class, {}) catch |err| {
                self.errorAtPrevious("Couldn't allocate class");
                self.lastError = err;
                return;
            };
            self.emit(OP.CONSTANT, self.makeConstant(Value.init(cls)));
            self.consume(Token.LEFT_BRACE, "Expect '{' before class body");

            var curcls = Class{ .enclosing = self.currentClass };
            self.currentClass = &curcls;
            while (!self.check(Token.RIGHT_BRACE) and !self.check(Token.EOF)) {
                self.method();
            }
            self.currentClass = self.currentClass.?.enclosing;

            self.consume(Token.RIGHT_BRACE, "Expect '}' after class body");
        }

        fn method(self: *Self) void {
            self.consume(Token.IDENTIFIER, "Expect method name");
            const constant = self.identifierConstant(self.previous) catch return;
            self.function(true, self.previous.lexeme);
            self.emit(OP.METHOD, constant);
        }

        fn funDeclaration(self: *Self) void {
            const global = self.parseVariable("Expect function name.", true) catch return;
            self.markInitialized();
            self.function(false, self.previous.lexeme);
            self.defineVariable(global, true);
        }

        fn funExpression(self: *Self, _: bool) void {
            self.function(false, "<anon>");
        }

        fn function(self: *Self, isMethod: bool, name: []const u8) void {
            const chunk = self.objects.emplace(.Chunk, {}) catch |err| {
                self.errorAtPrevious("Couldn't allocate chunk");
                self.lastError = err;
                return;
            };

            var compiler = Self.init_enclosed(self, chunk) catch |err| {
                self.errorAtPrevious("Couldn't init enclosed function");
                self.lastError = err;
                return;
            };

            compiler.initializer = isMethod and std.mem.eql(u8, name, "init");

            compiler.objects.push_callback(&gc_callback, &compiler) catch @panic("Couln't push callback");
            defer compiler.objects.pop_callback();

            var arity: u8 = 0;

            compiler.consume(Token.LEFT_PAREN, "Expect '(' in function definition");
            if (!compiler.check(Token.RIGHT_PAREN)) {
                while (true) {
                    if (arity == std.math.maxInt(@TypeOf(arity))) {
                        self.errorAtCurrent("Too many arguments to a function");
                        return;
                    }
                    arity += 1;
                    compiler.defineVariable(compiler.parseVariable("Expect parameter name.", true) catch return, true);
                    if (!compiler.match(Token.COMMA)) break;
                }
            }
            compiler.consume(Token.RIGHT_PAREN, "Expect ')' after parameters");

            var offset: usize = 0;

            if (isMethod) {
                compiler.locals[0] = .{
                    .name = scanner.Token{ .type = Token.THIS, .lexeme = "this", .line = -1, .column = 0 },
                    .depth = compiler.scopeDepth,
                };
                compiler.emit(OP.GET_UPVALUE, 0);
                offset = compiler.chunk.code.ptr().len - 1;
                compiler.emit(OP.SET_LOCAL, 0);
                compiler.emitOP(OP.POP);
            }

            compiler.consume(Token.LEFT_BRACE, "Expect '{' before function body");

            compiler.block();

            if (isMethod)
                compiler.chunk.code.ptr().set(offset, compiler.upvaluesCount) catch unreachable;

            self.current = compiler.current;

            if (compiler.hadError) {
                self.lastError = compiler.lastError;
            } else {
                const endchunk = compiler.end() catch return;
                if (compiler.upvaluesCount == 0) {
                    const fun = self.objects.emplace(.Function, .{
                        .type = .Function,
                        .chunk = endchunk,
                        .arity = arity,
                    }) catch |err| {
                        self.errorAtPrevious("Couldn't allocate function");
                        self.lastError = err;
                        return;
                    };
                    self.emit(OP.CONSTANT, self.makeConstant(Value.init(fun.cast())));
                } else {
                    self.emit(OP.CLOSURE, self.makeConstant(Value.init(endchunk.cast())));

                    self.emitByte(arity);
                    self.emitByte(compiler.upvaluesCount);
                    for (compiler.upvalues[0..compiler.upvaluesCount]) |upvalue| {
                        self.emitByte(@intFromEnum(upvalue.type));
                        self.emitByte(upvalue.index);
                    }
                }
            }
        }

        fn varDeclaration(self: *Self) void {
            const global = self.parseVariable("Expect variable name.", false) catch return;

            if (self.match(Token.EQUAL)) {
                self.expression();
            } else {
                self.emitOP(OP.NIL);
            }

            self.consume(Token.SEMICOLON, "Expect ';' after variable declaration.");

            self.defineVariable(global, false);
        }

        fn conDeclaration(self: *Self) void {
            const global = self.parseVariable("Expect variable name.", true) catch return;

            self.consume(Token.EQUAL, "Constant variable has to be initialized.");

            self.expression();

            self.consume(Token.SEMICOLON, "Expect ';' after variable declaration.");

            self.defineVariable(global, true);
        }

        fn parseVariable(self: *Self, errorMessage: []const u8, con: bool) !u8 {
            self.consume(Token.IDENTIFIER, errorMessage);

            self.declareVariable(con);
            if (self.scopeDepth > 0) return 0;

            return self.identifierConstant(self.previous);
        }

        fn identifierConstant(self: *Self, tok: scanner.Token) !u8 {
            return self.makeConstant(Value.init(self.objects.emplace_cast(.String, &.{tok.lexeme}) catch |err| {
                self.lastError = err;
                self.errorAtPrevious("Couldn't allocate identifier");
                return err;
            }));
        }

        fn declareVariable(self: *Self, con: bool) void {
            if (self.scopeDepth == 0) return;

            var i = self.localCount;
            while (i > 0) : (i -= 1) {
                const local = self.locals[i - 1];
                if (local.depth) |depth| {
                    if (depth < self.scopeDepth) break;
                }

                if (identifiersEql(local.name, self.previous)) {
                    self.errorAtPrevious("Already a variable with this name in this scope.");
                }
            }

            self.addLocal(self.previous, con);
        }

        fn identifiersEql(a: scanner.Token, b: scanner.Token) bool {
            return std.mem.eql(u8, a.lexeme, b.lexeme);
        }

        fn addLocal(self: *Self, name: scanner.Token, con: bool) void {
            if (self.localCount == size) {
                self.errorAt(name, "Too many variables in function");
                return;
            }
            self.locals[self.localCount] = Local{ .name = name, .con = con };
            self.localCount += 1;
        }

        fn markInitialized(self: *Self) void {
            if (self.scopeDepth == 0) return;
            self.locals[self.localCount - 1].depth = self.scopeDepth;
        }

        fn defineVariable(self: *Self, global: u8, con: bool) void {
            if (self.scopeDepth > 0) {
                self.markInitialized();
                return;
            }

            if (con) {
                self.emit(OP.DEFINE_GLOBAL_CONSTANT, global);
            } else {
                self.emit(OP.DEFINE_GLOBAL, global);
            }
        }

        fn synchronize(self: *Self) void {
            self.panicMode = false;

            while ((self.current.type catch Token.NIL) != Token.EOF) {
                if ((self.previous.type catch Token.NIL) == Token.SEMICOLON) return;
                switch (self.current.type catch Token.NIL) {
                    Token.CLASS, Token.VAR, Token.CON, Token.IF, Token.FOR, Token.WHILE, Token.SWITCH, Token.PRINT, Token.LEFT_BRACE, Token.RETURN => return,
                    else => self.advance(),
                }
            }
        }

        fn statement(self: *Self) void {
            if (self.match(Token.PRINT)) {
                self.printStatement();
            } else if (self.match(Token.IF)) {
                self.ifStatement();
            } else if (self.match(Token.RETURN)) {
                self.returnStatement();
            } else if (self.match(Token.WHILE)) {
                self.whileStatement();
            } else if (self.match(Token.FOR)) {
                self.forStatement();
            } else if (self.match(Token.SWITCH)) {
                self.switchStatement();
            } else if (self.match(Token.LEFT_BRACE)) {
                self.beginScope();
                self.block();
                self.endScope();
            } else {
                self.expressionStatement();
            }
        }

        fn returnStatement(self: *Self) void {
            if (self.enclosing == null) {
                self.errorAtPrevious("Can't return from top-level code");
                return;
            }
            if (self.match(Token.SEMICOLON)) {
                self.emitReturn();
            } else if (self.initializer) {
                self.errorAtCurrent("Can't return a value from an initializer");
            } else {
                self.expression();
                self.consume(Token.SEMICOLON, "Expect ';' after return value");
                self.emitOP(OP.RETURN);
            }
        }

        fn switchStatement(self: *Self) void {
            var defaultPresent = false;
            var argCount: u8 = 0;

            self.consume(Token.LEFT_PAREN, "Expect '(' after 'switch'.");

            self.emitObj(.Native, Obj.Native.Arg{
                .fun = vm_native.table,
            }) catch return;

            var jumpOver = self.emitJump(OP.JUMP);
            const switchExpression = self.chunk.code.ptr().len;
            self.expression();

            self.consume(Token.RIGHT_PAREN, "Expect ')' after expression");

            self.emitOP(OP.GET_INDEX);
            const defaultJump = self.emitJump(OP.JUMP_IF_FALSE);
            self.emitOP(OP.JUMP_POP);
            const switchJump = self.chunk.code.ptr().len;
            const exitJump = self.emitJump(OP.JUMP);

            self.patchJump(jumpOver);

            self.consume(Token.LEFT_BRACE, "Expect '{' after switch()");

            while (!self.match(Token.RIGHT_BRACE)) {
                if (self.match(Token.CASE)) {
                    self.expression();
                    argCount += 2;
                    const distance = self.chunk.code.ptr().len - switchJump + 5;
                    if (distance > std.math.maxInt(u52)) {
                        self.errorAtCurrent("Switch body too large");
                        return;
                    }
                    self.emitConstant(Value.init(@as(Value.tagType(.number), @floatFromInt(distance))));
                    jumpOver = self.emitJump(OP.JUMP);
                } else if (self.match(Token.DEFAULT)) {
                    if (defaultPresent) {
                        self.errorAtCurrent("Duplicate default");
                        return;
                    }
                    jumpOver = self.emitJump(OP.JUMP);
                    self.patchJump(defaultJump);
                    self.emitOP(OP.POP);
                    defaultPresent = true;
                } else {
                    self.errorAtCurrent("Expect 'case' or 'default'");
                    return;
                }
                self.consume(Token.COLON, "Expect ':' after case");
                self.statement();
                self.emitLoop(switchJump);
                self.patchJump(jumpOver);
            }
            self.emit(OP.CALL, argCount);
            self.emitLoop(switchExpression);

            if (!defaultPresent) {
                self.patchJump(defaultJump);
                self.emitOP(OP.POP);
                self.emitLoop(switchJump);
            }

            self.patchJump(exitJump);
        }

        fn whileStatement(self: *Self) void {
            const loopStart = self.chunk.code.ptr().len;

            self.consume(Token.LEFT_PAREN, "Expect '(' after 'while'.");
            self.expression();
            self.consume(Token.RIGHT_PAREN, "Expect ')' after condition");

            const exitJump = self.emitJump(OP.JUMP_IF_FALSE);
            self.emitOP(OP.POP);
            if (!self.match(Token.SEMICOLON)) {
                self.statement();
            }
            self.emitLoop(loopStart);

            self.patchJump(exitJump);
            self.emitOP(OP.POP);
        }

        fn forStatement(self: *Self) void {
            self.beginScope();
            self.consume(Token.LEFT_PAREN, "Expect '(' after 'for'.");

            if (self.match(Token.SEMICOLON)) {
                // Empty initializer
            } else if (self.match(Token.VAR)) {
                self.varDeclaration();
            } else if (self.match(Token.CON)) {
                self.conDeclaration();
            } else {
                self.expressionStatement();
            }

            var loopStart = self.chunk.code.ptr().len;

            var exitJump: ?usize = null;
            if (!self.match(Token.SEMICOLON)) {
                self.expression();
                self.consume(Token.SEMICOLON, "Expect ';' after condition clause");

                exitJump = self.emitJump(OP.JUMP_IF_FALSE);
                self.emitOP(OP.POP);
            }

            if (!self.match(Token.RIGHT_PAREN)) {
                const bodyJump = self.emitJump(OP.JUMP);
                const incrementStart = self.chunk.code.ptr().len;
                self.expression();
                self.emitOP(OP.POP);
                self.consume(Token.RIGHT_PAREN, "Expect ')' after increment clause");

                self.emitLoop(loopStart);
                loopStart = incrementStart;
                self.patchJump(bodyJump);
            }
            if (!self.match(Token.SEMICOLON)) {
                self.statement();
            }
            self.emitLoop(loopStart);

            if (exitJump) |jump| {
                self.patchJump(jump);
                self.emitOP(OP.POP);
            }
            self.endScope();
        }

        fn emitLoop(self: *Self, start: usize) void {
            self.emitOP(OP.LOOP);
            const offset = self.chunk.code.ptr().len - start + 2;

            if (offset > std.math.maxInt(u16)) {
                self.errorAtPrevious("Loop body too large");
                return;
            }

            self.emitByte(@intCast((offset >> 8) & 0xff));
            self.emitByte(@intCast(offset & 0xff));
        }

        fn ifStatement(self: *Self) void {
            self.consume(Token.LEFT_PAREN, "Expect '(' after 'if'.");
            self.expression();
            self.consume(Token.RIGHT_PAREN, "Expect ')' after condition");

            const thenJump = self.emitJump(OP.JUMP_IF_FALSE);
            self.emitOP(OP.POP);
            self.statement();
            const elseJump = self.emitJump(OP.JUMP);
            self.patchJump(thenJump);
            self.emitOP(OP.POP);
            if (self.match(Token.ELSE)) self.statement();
            self.patchJump(elseJump);
        }

        fn emitJump(self: *Self, instruction: OP) usize {
            self.emitOP(instruction);
            self.emitByte(0xff);
            self.emitByte(0xff);
            return self.chunk.code.ptr().len - 2;
        }

        fn patchJump(self: *Self, offset: usize) void {
            const jump = self.chunk.code.ptr().len - offset - 2;
            if (jump > std.math.maxInt(u16)) {
                self.errorAtPrevious("Jump too large");
                return;
            }

            self.chunk.code.ptr().set(offset, @intCast((jump >> 8) & 0xff)) catch {
                self.errorAtPrevious("Invalid jump offset");
            };
            self.chunk.code.ptr().set(offset + 1, @intCast(jump & 0xff)) catch {
                self.errorAtPrevious("Invalid jump offset");
            };
        }

        fn block(self: *Self) void {
            while (!self.check(Token.RIGHT_BRACE) and !self.check(Token.EOF)) {
                self.declaration();
            }

            self.consume(Token.RIGHT_BRACE, "Expect '}' after block.");
        }

        fn beginScope(self: *Self) void {
            self.scopeDepth += 1;
        }

        fn endScope(self: *Self) void {
            self.scopeDepth -= 1;

            while (self.localCount > 0) {
                if (self.locals[self.localCount - 1].depth) |depth| {
                    if (depth <= self.scopeDepth) break;
                } else {
                    self.errorAt(self.locals[self.localCount - 1].name, "Unitialized variable at scope end");
                }
                if (self.locals[self.localCount - 1].captured) {
                    self.emitOP(OP.CLOSE_UPVALUE);
                } else {
                    self.emitOP(OP.POP);
                }
                self.localCount -= 1;
            }
        }

        fn expressionStatement(self: *Self) void {
            self.expression();
            self.consume(Token.SEMICOLON, "Expect ';' after expression.");
            self.emitOP(OP.POP);
        }

        fn match(self: *Self, token: Token) bool {
            if (!self.check(token)) return false;
            self.advance();
            return true;
        }

        fn check(self: *const Self, token: Token) bool {
            return if (self.current.type) |tp| tp == token else |_| false;
        }

        fn printStatement(self: *Self) void {
            self.expression();
            self.consume(Token.SEMICOLON, "Expect ';' after value.");
            self.emitOP(OP.PRINT);
        }

        fn init(scan: *scanner.Scanner, objects: *GC, chunk: *Obj.Chunk) !Self {
            var self = Self{
                .scanner = scan,
                .current = scanner.Token.Empty,
                .previous = scanner.Token.Empty,
                .panicMode = false,
                .hadError = false,
                .lastError = scanner.ScannerError.EmptyToken,
                .chunk = chunk,
                .objects = objects,
                .locals = @splat(Local{}),
                .localCount = 1,
                .scopeDepth = 0,
                .enclosing = null,
                .upvalues = @splat(Upvalue{ .index = 0, .type = .local }),
                .upvaluesCount = 0,
                .currentClass = null,
                .initializer = false,
            };
            self.locals[0].depth = 0;

            return self;
        }

        fn init_enclosed(enclosing: *Self, chunk: *Obj.Chunk) !Self {
            var enclosed = try Self.init(enclosing.scanner, enclosing.objects, chunk);
            enclosed.current = enclosing.current;
            enclosed.enclosing = enclosing;
            enclosed.currentClass = enclosing.currentClass;
            enclosed.beginScope();

            return enclosed;
        }

        fn gc_callback(self_ptr: *anyopaque) void {
            var self: *@This() = @ptrCast(@alignCast(self_ptr));

            self.objects.mark("C", self.chunk);
        }

        pub fn compile(source: []const u8, objects: *GC) CompilerError!*Obj.Chunk {
            var scan = try scanner.Scanner.init(source);
            const chunk = try objects.emplace(.Chunk, {});
            var self = try Self.init(&scan, objects, chunk);

            try objects.push_callback(&gc_callback, &self);
            defer objects.pop_callback();

            self.advance();

            while (!self.match(Token.EOF)) {
                self.declaration();
            }

            return if (self.hadError) self.lastError else try self.end();
        }
    };
}
