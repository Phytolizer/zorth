const std = @import("std");
const known_folders = @import("known-folders");

const Op = union(enum) {
    PUSH: i64,
    PLUS,
    MINUS,
    DUMP,

    const TAG_NAMES = init: {
        var result: []const []const u8 = &[_][]const u8{};
        inline for (std.meta.fieldNames(@This())) |fld| {
            var lowerField: [fld.len]u8 = undefined;
            for (fld) |c, i| {
                lowerField[i] = std.ascii.toLower(c);
            }
            result = result ++ [_][]const u8{&lowerField};
        }
        break :init result;
    };

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .PUSH => |x| try writer.print("push {d}", .{x}),
            else => try writer.writeAll(TAG_NAMES[@enumToInt(std.meta.activeTag(self))]),
        }
    }
};
const COUNT_OPS = @typeInfo(Op).Union.fields.len;

var a: std.mem.Allocator = undefined;

const PROGRAM = [_]Op{
    .{ .PUSH = 34 },
    .{ .PUSH = 35 },
    .PLUS,
    .DUMP,
    .{ .PUSH = 500 },
    .{ .PUSH = 80 },
    .MINUS,
    .DUMP,
};

fn notImplemented() noreturn {
    std.log.err("not implemented", .{});
    unreachable;
}

fn pop(stack: anytype) !@typeInfo(@TypeOf(stack.items)).Pointer.child {
    comptime switch (@typeInfo(@TypeOf(stack))) {
        .Pointer => |p| {
            std.debug.assert(p.size == .One);
            std.debug.assert(!p.is_const);
        },
        else => unreachable,
    };
    return stack.popOrNull() orelse return error.StackUnderflow;
}

fn simulateProgram(program: []const Op) !void {
    var stack = std.ArrayList(i64).init(a);
    defer stack.deinit();
    for (program) |op| {
        switch (op) {
            .PUSH => |x| {
                try stack.append(x);
            },
            .PLUS => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x + y);
            },
            .MINUS => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x - y);
            },
            .DUMP => {
                const x = try pop(&stack);
                std.debug.print("{d}\n", .{x});
            },
        }
    }
}

fn temp() ![]const u8 {
    const cacheDir = try known_folders.getPath(a, .cache);
    defer if (cacheDir) |cd| a.free(cd);
    return try std.fs.path.join(a, &.{ cacheDir orelse ".", "zorth", "intermediate" });
}

var temp_dir: std.fs.Dir = undefined;
var temp_path: []const u8 = undefined;

fn runCmd(argv: []const []const u8) !void {
    var child = std.ChildProcess.init(argv, a);
    const result = try child.spawnAndWait();
    const was_ok = switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!was_ok) {
        std.log.err("command {s} exited with error", .{argv[0]});
        return error.Cmd;
    }
}

fn compileProgram(program: []const Op) !void {
    const dump = @embedFile("dump.nasm");
    // emit asm
    {
        var temp_nasm = try temp_dir.createFile("out.nasm", .{});
        defer temp_nasm.close();

        const w = temp_nasm.writer();
        try w.writeAll(dump);
        try w.writeAll(
            \\
            \\    section .text
            \\    global _start
            \\_start:
            \\
        );
        for (program) |op| {
            try w.print("    ;; -- {} --\n", .{op});
            switch (op) {
                .PUSH => |x| try w.print(
                    \\    push {d}
                    \\
                , .{x}),
                .PLUS => try w.writeAll(
                    \\    pop rbx
                    \\    pop rax
                    \\    add rax, rbx
                    \\    push rax
                    \\
                ),
                .MINUS => try w.writeAll(
                    \\    pop rbx
                    \\    pop rax
                    \\    sub rax, rbx
                    \\    push rax
                    \\
                ),
                .DUMP => try w.writeAll(
                    \\    pop rdi
                    \\    call dump
                    \\
                ),
            }
        }
        try w.writeAll(
            \\pop rdi
            \\mov rax, 60
            \\syscall
            \\
        );
    }

    // compile asm
    const src_path = try std.fs.path.join(a, &.{ temp_path, "out.nasm" });
    defer a.free(src_path);
    const obj_path = try std.fs.path.join(a, &.{ temp_path, "out.o" });
    defer a.free(obj_path);
    try runCmd(&.{ "nasm", "-f", "elf64", src_path, "-o", obj_path });
    try runCmd(&.{ "ld", "-o", obj_path[0 .. obj_path.len - 2], obj_path });
}

pub fn main() void {
    run() catch std.process.exit(1);
}

fn usage(program_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} <SUBCOMMAND> [ARGS]
        \\SUBCOMMANDS:
        \\    sim           Simulate the program
        \\    com           Compile the program
        \\
    , .{program_name});
}

fn streq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    a = gpa.allocator();
    temp_path = try temp();
    defer a.free(temp_path);
    temp_dir = try std.fs.cwd().makeOpenPath(temp_path, .{});
    defer temp_dir.close();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    if (args.len < 2) {
        usage(args[0]);
        std.log.err("no subcommand provided", .{});
        return error.Usage;
    }

    const subcommand = args[1];
    if (streq(subcommand, "sim")) {
        try simulateProgram(&PROGRAM);
    } else if (streq(subcommand, "com")) {
        try compileProgram(&PROGRAM);
    } else {
        usage(args[0]);
        std.log.err("unknown subcommand '{s}'", .{subcommand});
        return error.Usage;
    }
}
