const std = @import("std");
const known_folders = @import("known-folders");

const Op = struct {
    code: Code,

    pub fn init(code: Code) @This() {
        return .{ .code = code };
    }

    const Code = union(enum) {
        PUSH: i64,
        PLUS,
        MINUS,
        EQUAL,
        IF: usize,
        ELSE: usize,
        END: usize,
        DUP,
        GT,
        WHILE,
        DO: usize,
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

        fn tagName(self: @This()) []const u8 {
            return TAG_NAMES[@enumToInt(std.meta.activeTag(self))];
        }

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .PUSH => |x| try writer.print("{s} {d}", .{ tagName(self), x }),
                else => try writer.writeAll(tagName(self)),
            }
        }
    };
    const COUNT_OPS = @typeInfo(Op).Union.fields.len;
};

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
    var ip: usize = 0;
    while (ip < program.len) {
        const op = program[ip];
        switch (op.code) {
            .PUSH => |x| {
                try stack.append(x);
                ip += 1;
            },
            .PLUS => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x + y);
                ip += 1;
            },
            .MINUS => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x - y);
                ip += 1;
            },
            .EQUAL => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x == y));
                ip += 1;
            },
            .IF => |dest| {
                const x = try pop(&stack);
                ip = if (x == 0)
                    dest
                else
                    ip + 1;
            },
            .ELSE => |dest| {
                ip = dest;
            },
            .END => |dest| {
                ip = dest;
            },
            .DUP => {
                const x = try pop(&stack);
                try stack.appendNTimes(x, 2);
                ip += 1;
            },
            .GT => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x > y));
                ip += 1;
            },
            .WHILE => {
                ip += 1;
            },
            .DO => |dest| {
                const x = try pop(&stack);
                ip = if (x == 0)
                    dest
                else
                    ip + 1;
            },
            .DUMP => {
                const x = try pop(&stack);
                std.debug.print("{d}\n", .{x});
                ip += 1;
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
    for (program) |op, ip| {
        try w.print(
            \\    ;; -- {} --
            \\.zorth_addr_{d}:
            \\
        , .{ op, ip });
        switch (op.code) {
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
            .EQUAL => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmove rcx, rdx
                \\    push rcx
                \\
            ),
            .IF => |dest| try w.print(
                \\    pop rax
                \\    test rax, rax
                \\    jz .zorth_addr_{d}
                \\
            , .{dest}),
            .ELSE => |dest| try w.print(
                \\    jmp .zorth_addr_{d}
                \\
            , .{dest}),
            .END => |dest| {
                if (dest != ip + 1) try w.print(
                    \\    jmp .zorth_addr_{d}
                    \\
                , .{dest});
            },
            .DUP => try w.writeAll(
                \\    pop rax
                \\    push rax
                \\    push rax
                \\
            ),
            .GT => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmovg rcx, rdx
                \\    push rcx
                \\
            ),
            .WHILE => {},
            .DO => |dest| try w.print(
                \\    pop rax
                \\    test rax, rax
                \\    jz .zorth_addr_{d}
                \\
            , .{dest}),
            .DUMP => try w.writeAll(
                \\    pop rdi
                \\    call dump
                \\
            ),
        }
    }
    try w.print(
        \\.zorth_addr_{d}:
        \\    mov rdi, 0
        \\    mov rax, 60
        \\    syscall
        \\
    , .{program.len});
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
    if (streq(token.word, "+")) {
        return Op.init(.PLUS);
    } else if (streq(token.word, "-")) {
        return Op.init(.MINUS);
    } else if (streq(token.word, "=")) {
        return Op.init(.EQUAL);
    } else if (streq(token.word, "if")) {
        return Op.init(.{ .IF = undefined });
    } else if (streq(token.word, "else")) {
        return Op.init(.{ .ELSE = undefined });
    } else if (streq(token.word, "end")) {
        return Op.init(.{ .END = undefined });
    } else if (streq(token.word, "dup")) {
        return Op.init(.DUP);
    } else if (streq(token.word, ">")) {
        return Op.init(.GT);
    } else if (streq(token.word, "while")) {
        return Op.init(.WHILE);
    } else if (streq(token.word, "do")) {
        return Op.init(.{ .DO = undefined });
    } else if (streq(token.word, ".")) {
        return Op.init(.DUMP);
    } else {
        return Op.init(.{ .PUSH = try std.fmt.parseInt(i64, token.word, 10) });
    }
}

fn resolveJumps(program: []Op) !void {
    var stack = std.ArrayList(usize).init(a);
    defer stack.deinit();
    for (program) |*op, ip| {
        switch (op.code) {
            .IF, .WHILE => try stack.append(ip),
            .ELSE => {
                const if_ip = try pop(&stack);
                switch (program[if_ip].code) {
                    .IF => |*dest| {
                        dest.* = ip + 1;
                        try stack.append(ip);
                    },
                    else => {
                        std.log.err("`else` without `if`", .{});
                        return error.Parse;
                    },
                }
            },
            .DO => |*dest| {
                const while_ip = try pop(&stack);
                dest.* = while_ip;
                try stack.append(ip);
            },
            .END => |*end_dest| {
                const block_ip = try pop(&stack);
                switch (program[block_ip].code) {
                    .IF, .ELSE => |*dest| {
                        dest.* = ip;
                        end_dest.* = ip + 1;
                    },
                    .DO => |*dest| {
                        end_dest.* = dest.*;
                        dest.* = ip + 1;
                    },
                    else => {
                        std.log.err("`end` without `if`/`do`", .{});
                        return error.Parse;
                    },
                }
            },
            else => {},
        }
    }
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

    fn trimComment(line: []const u8) []const u8 {
        return if (std.mem.indexOf(u8, line, "//")) |comment_start|
            line[0..comment_start]
        else
            line;
    }

    pub fn init(file_path: []const u8, source: []const u8) @This() {
        var lines = std.mem.split(u8, source, &.{'\n'});
        return .{
            .file_path = file_path,
            .source = source,
            .line = trimComment(lines.first()),
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
                self.line = trimComment(next_line);
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
    var ops = std.ArrayList(Op).init(a);
    errdefer ops.deinit();
    while (lexer.next()) |token| {
        try ops.append(try parseTokenAsOp(token));
    }
    var result = try ops.toOwnedSlice();
    try resolveJumps(result);
    return result;
}

fn usage(writer: anytype, program_name: []const u8) !void {
    try writer.print(
        \\Usage: {s} <SUBCOMMAND> [ARGS]
        \\SUBCOMMANDS:
        \\  sim <file>                 Simulate the program
        \\  com [OPTIONS] <file>       Compile the program
        \\    OPTIONS:
        \\      -r                       Run the program after compilation
        \\      -o <file|dir>            Set the output path
        \\  help                       Print this help to stdout
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
        var do_run = false;
        var maybe_program_path: ?[]const u8 = null;
        var maybe_output_path: ?[]const u8 = null;
        while (args.len > 0) {
            const arg = uncons(&args);
            if (streq(arg, "-r")) {
                do_run = true;
            } else if (streq(arg, "-o")) {
                if (args.len == 0) {
                    try usage(stderr, program_name);
                    std.log.err("argument for `-o` not provided", .{});
                    return error.Usage;
                }
                maybe_output_path = uncons(&args);
            } else {
                maybe_program_path = arg;
                break;
            }
        }
        const program_path = maybe_program_path orelse {
            try usage(stderr, program_name);
            std.log.err("no input file provided for compilation", .{});
            return error.Usage;
        };
        const program = try loadProgramFromFile(program_path);
        defer a.free(program);
        var basename = std.fs.path.basename(program_path);
        const extension = std.fs.path.extension(basename);
        if (streq(extension, ".zorth")) {
            basename = basename[0 .. basename.len - ".zorth".len];
        }
        var basedir = std.fs.path.dirname(program_path) orelse ".";
        if (maybe_output_path) |output_path| {
            const is_dir = if (std.fs.cwd().statFile(output_path)) |status|
                status.kind == .Directory
            else |_|
                false;
            if (is_dir) {
                basedir = output_path;
            } else {
                basename = std.fs.path.basename(output_path);
                basedir = std.fs.path.dirname(output_path) orelse ".";
            }
        }
        const src_path = try std.mem.concat(a, u8, &.{ temp_path, "/", basename, ".nasm" });
        defer a.free(src_path);
        std.log.info("Generating {s}", .{src_path});
        try compileProgram(program, src_path);
        const obj_path = try std.mem.concat(a, u8, &.{ temp_path, "/", basename, ".o" });
        defer a.free(obj_path);
        try runCmd(&.{ "nasm", "-f", "elf64", src_path, "-o", obj_path });
        const exe_path = try std.fs.path.join(a, &.{ basedir, basename });
        defer a.free(exe_path);
        try runCmd(&.{ "ld", "-o", exe_path, obj_path });
        if (do_run) {
            try runCmd(&.{exe_path});
        }
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
