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
    std.debug.print("cmd:", .{});
    for (argv) |arg| {
        std.debug.print(" '{s}'", .{arg});
    }
    std.debug.print("\n", .{});
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

fn compileProgram(program: []const Op, out_path: []const u8) !void {
    const dump = @embedFile("dump.nasm");
    var temp_nasm = try temp_dir.createFile(out_path, .{});
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
        \\mov rdi, 0
        \\mov rax, 60
        \\syscall
        \\
    );
}

const Token = struct {
    file_path: []const u8,
    row: usize,
    col: usize,
    word: []const u8,
};

fn parseTokenAsOp(token: Token) !Op {
    errdefer |e| {
        std.debug.print("{s}:{d}:{d}: {s}\n", .{
            token.file_path,
            token.row,
            token.col,
            @errorName(e),
        });
    }
    return if (streq(token.word, "+"))
        .PLUS
    else if (streq(token.word, "-"))
        .MINUS
    else if (streq(token.word, "."))
        .DUMP
    else .{ .PUSH = try std.fmt.parseInt(i64, token.word, 10) };
}

fn indexOfNonePos(comptime T: type, slice: []const T, start_index: usize, values: []const T) ?usize {
    var i: usize = start_index;
    chars: while (i < slice.len) : (i += 1) {
        for (values) |value| {
            if (slice[i] == value) continue :chars;
        }
        return i;
    }
    return null;
}

const Lexer = struct {
    file_path: []const u8,
    row: usize = 0,
    col: usize = 0,
    source: []const u8,
    lines: std.mem.SplitIterator(u8),
    line: []const u8,

    pub fn init(file_path: []const u8, source: []const u8) @This() {
        var lines = std.mem.split(u8, source, &.{'\n'});
        return .{
            .file_path = file_path,
            .source = source,
            .line = lines.first(),
            .lines = lines,
        };
    }

    pub fn next(self: *@This()) ?Token {
        while (true) {
            const maybe_col = indexOfNonePos(u8, self.line, self.col, &std.ascii.whitespace);
            if (maybe_col) |col| {
                const col_end = std.mem.indexOfAnyPos(u8, self.line, col, &std.ascii.whitespace) orelse self.line.len;
                const result = Token{
                    .file_path = self.file_path,
                    .row = self.row + 1,
                    .col = col + 1,
                    .word = self.line[col..col_end],
                };
                self.col = col_end;
                return result;
            } else if (self.lines.next()) |next_line| {
                self.line = next_line;
                self.col = 0;
                self.row += 1;
            } else {
                return null;
            }
        }
    }
};

fn loadProgramFromFile(path: []const u8) ![]Op {
    const contents = try std.fs.cwd().readFileAlloc(a, path, std.math.maxInt(usize));
    defer a.free(contents);
    var lexer = Lexer.init(path, contents);
    var result = std.ArrayList(Op).init(a);
    errdefer result.deinit();
    while (lexer.next()) |token| {
        try result.append(try parseTokenAsOp(token));
    }
    return try result.toOwnedSlice();
}

fn usage(writer: anytype, program_name: []const u8) !void {
    try writer.print(
        \\Usage: {s} <SUBCOMMAND> [ARGS]
        \\SUBCOMMANDS:
        \\    sim <file>      Simulate the program
        \\    com <file>      Compile the program
        \\    help            Print this help to stdout
        \\
    , .{program_name});
}

fn streq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn uncons(argv: *[][]const u8) []const u8 {
    const first = argv.*[0];
    argv.* = argv.*[1..];
    return first;
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    a = gpa.allocator();
    temp_path = try temp();
    defer a.free(temp_path);
    temp_dir = try std.fs.cwd().makeOpenPath(temp_path, .{});
    defer temp_dir.close();
    const orig_args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, orig_args);
    var args = orig_args;

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    const program_name = uncons(&args);
    if (args.len < 1) {
        try usage(stderr, program_name);
        std.log.err("no subcommand provided", .{});
        return error.Usage;
    }

    const subcommand = uncons(&args);
    if (streq(subcommand, "sim")) {
        if (args.len < 1) {
            try usage(stderr, program_name);
            std.log.err("no input file provided for simulation", .{});
            return error.Usage;
        }
        const program_path = uncons(&args);
        const program = try loadProgramFromFile(program_path);
        defer a.free(program);
        try simulateProgram(program);
    } else if (streq(subcommand, "com")) {
        if (args.len < 1) {
            try usage(stderr, program_name);
            std.log.err("no input file provided for compilation", .{});
            return error.Usage;
        }
        const program_path = uncons(&args);
        const program = try loadProgramFromFile(program_path);
        defer a.free(program);
        var basename = std.fs.path.basename(program_path);
        const extension = std.fs.path.extension(basename);
        if (streq(extension, ".zorth")) {
            basename = basename[0 .. basename.len - ".zorth".len];
        }
        const src_path = try std.mem.concat(a, u8, &.{ temp_path, "/", basename, ".nasm" });
        defer a.free(src_path);
        std.log.info("Generating {s}", .{src_path});
        try compileProgram(program, src_path);
        const obj_path = try std.mem.concat(a, u8, &.{ temp_path, "/", basename, ".o" });
        defer a.free(obj_path);
        try runCmd(&.{ "nasm", "-f", "elf64", src_path, "-o", obj_path });
        const dirname = std.fs.path.dirname(program_path) orelse ".";
        const exe_path = try std.fs.path.join(a, &.{ dirname, basename });
        defer a.free(exe_path);
        try runCmd(&.{ "ld", "-o", exe_path, obj_path });
    } else if (streq(subcommand, "help")) {
        try usage(stdout, program_name);
        return;
    } else {
        try usage(stderr, program_name);
        std.log.err("unknown subcommand '{s}'", .{subcommand});
        return error.Usage;
    }
}

pub fn main() void {
    run() catch std.process.exit(1);
}
