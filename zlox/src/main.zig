const std = @import("std");
const linenoise = @import("linenoise");

const vm = @import("vm.zig");

pub fn main(init: std.process.Init) anyerror!u8 {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1) {
        try repl(allocator, io, false);
    } else if (args.len == 2) {
        if (std.mem.eql(u8, args[1], "-d")) {
            try repl(allocator, io, true);
        } else {
            try runFile(allocator, io, args[1], false);
        }
    } else if (args.len == 3) {
        if (std.mem.eql(u8, args[1], "-d")) {
            try runFile(allocator, io, args[2], true);
        } else {
            try runFile(allocator, io, args[1], true);
        }
    } else {
        std.debug.print("Usage: {s} [path]\n", .{args[0]});
        return 64;
    }

    return 0;
}

pub fn runFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, dbg: bool) anyerror!void {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.unlimited);
    defer allocator.free(text);
    var VM = try vm.VM.init(allocator, io);
    defer VM.deinit();

    try VM.interpret(text, dbg);
}

pub fn repl(allocator: std.mem.Allocator, io: std.Io, dbg: bool) anyerror!void {
    var VM = try vm.VM.init(allocator, io);
    defer VM.deinit();

    _ = linenoise.linenoiseHistorySetMaxLen(100);

    while (linenoise.linenoise("lox> ")) |line| {
        defer linenoise.linenoiseFree(line);
        VM.interpret(std.mem.span(line), dbg) catch |err| {
            std.debug.print("\nError: {any}\n", .{err});
        };
        _ = linenoise.linenoiseHistoryAdd(line);
    }
}
