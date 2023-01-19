const std = @import("std");
const known_folders = @import("known-folders");
const common = @import("common.zig");

const Op = struct {
    code: Code,
    loc: Token,

    pub fn init(code: Code, loc: Token) @This() {
        return .{
            .code = code,
            .loc = loc,
        };
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
        DUP2,
        SWAP,
        DROP,
        GT,
        LT,
        WHILE,
        DO: usize,
        MEM,
        LOAD,
        STORE,
        DUMP,
        SYSCALL0,
        SYSCALL1,
        SYSCALL2,
        SYSCALL3,
        SYSCALL4,
        SYSCALL5,
        SYSCALL6,

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
    };

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.code) {
            .PUSH => |x| try writer.print("{s} {d}", .{ Code.tagName(self.code), x }),
            else => try writer.writeAll(Code.tagName(self.code)),
        }
    }
    const COUNT_OPS = @typeInfo(Op).Union.fields.len;
};

const MEM_CAPACITY = 640_000;

var g_a: std.mem.Allocator = undefined;

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

fn simulateProgram(program: []const Op, stdout: anytype) !void {
    var stack = std.ArrayList(i64).init(g_a);
    defer stack.deinit();
    var ip: usize = 0;
    var mem = try g_a.alloc(u8, MEM_CAPACITY);
    defer g_a.free(mem);
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
            .DUP2 => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x);
                try stack.append(y);
                try stack.append(x);
                try stack.append(y);
                ip += 1;
            },
            .SWAP => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(y);
                try stack.append(x);
                ip += 1;
            },
            .DROP => {
                _ = try pop(&stack);
                ip += 1;
            },
            .GT => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x > y));
                ip += 1;
            },
            .LT => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x < y));
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
            .MEM => {
                try stack.append(0);
                ip += 1;
            },
            .LOAD => {
                const addr = try pop(&stack);
                const byte = mem[@intCast(usize, addr)];
                try stack.append(byte);
                ip += 1;
            },
            .STORE => {
                const value = try pop(&stack);
                const addr = try pop(&stack);
                mem[@intCast(usize, addr)] = @truncate(u8, @intCast(u63, value));
                ip += 1;
            },
            .DUMP => {
                const x = try pop(&stack);
                try stdout.print("{d}\n", .{x});
                ip += 1;
            },
            .SYSCALL0 => {
                return error.UnimplementedSyscall;
            },
            .SYSCALL1 => {
                return error.UnimplementedSyscall;
            },
            .SYSCALL2 => {
                return error.UnimplementedSyscall;
            },
            .SYSCALL3 => {
                const syscall_number = try pop(&stack);
                const arg1 = try pop(&stack);
                const arg2 = try pop(&stack);
                const arg3 = try pop(&stack);
                switch (syscall_number) {
                    1 => {
                        const fd = arg1;
                        const buf = @intCast(usize, arg2);
                        const count = @intCast(usize, arg3);
                        const s = mem[buf .. buf + count];
                        switch (fd) {
                            1 => try stdout.print("{s}", .{s}),
                            2 => std.debug.print("{s}", .{s}),
                            else => return error.UnknownFileDesc,
                        }
                    },
                    else => return error.UnimplementedSyscall,
                }
                ip += 1;
            },
            .SYSCALL4 => {
                return error.UnimplementedSyscall;
            },
            .SYSCALL5 => {
                return error.UnimplementedSyscall;
            },
            .SYSCALL6 => {
                return error.UnimplementedSyscall;
            },
        }
    }
}

fn temp() ![]const u8 {
    const cacheDir = try known_folders.getPath(g_a, .cache);
    defer if (cacheDir) |cd| g_a.free(cd);
    return try std.fs.path.join(g_a, &.{ cacheDir orelse ".", "zorth", "intermediate" });
}

var temp_dir: std.fs.Dir = undefined;
var temp_path: []const u8 = undefined;

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
            .DUP2 => try w.writeAll(
                \\    pop rbx
                \\    pop rax
                \\    push rax
                \\    push rbx
                \\    push rax
                \\    push rbx
                \\
            ),
            .SWAP => try w.writeAll(
                \\    pop rbx
                \\    pop rax
                \\    push rbx
                \\    push rax
                \\
            ),
            .DROP => try w.writeAll(
                \\    pop rax
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
            .LT => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmovl rcx, rdx
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
            .MEM => try w.writeAll(
                \\    push mem
                \\
            ),
            .LOAD => try w.writeAll(
                \\    pop rax
                \\    xor rbx, rbx
                \\    mov bl, [rax]
                \\    push rbx
                \\
            ),
            .STORE => try w.writeAll(
                \\    pop rbx
                \\    pop rax
                \\    mov [rax], bl
                \\
            ),
            .DUMP => try w.writeAll(
                \\    pop rdi
                \\    call dump
                \\
            ),
            .SYSCALL0 => try w.writeAll(
                \\    pop rax
                \\    syscall
                \\
            ),
            .SYSCALL1 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    syscall
                \\
            ),
            .SYSCALL2 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    syscall
                \\
            ),
            .SYSCALL3 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    pop rdx
                \\    syscall
                \\
            ),
            .SYSCALL4 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    pop rdx
                \\    pop r10
                \\    syscall
                \\
            ),
            .SYSCALL5 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    pop rdx
                \\    pop r10
                \\    pop r8
                \\    syscall
                \\
            ),
            .SYSCALL6 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    pop rdx
                \\    pop r10
                \\    pop r8
                \\    pop r9
                \\    syscall
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
        \\    section .bss
        \\mem: resb {d}
        \\
    , .{ program.len, MEM_CAPACITY });
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
        return Op.init(.PLUS, token);
    } else if (streq(token.word, "-")) {
        return Op.init(.MINUS, token);
    } else if (streq(token.word, "=")) {
        return Op.init(.EQUAL, token);
    } else if (streq(token.word, "if")) {
        return Op.init(.{ .IF = undefined }, token);
    } else if (streq(token.word, "else")) {
        return Op.init(.{ .ELSE = undefined }, token);
    } else if (streq(token.word, "end")) {
        return Op.init(.{ .END = undefined }, token);
    } else if (streq(token.word, "dup")) {
        return Op.init(.DUP, token);
    } else if (streq(token.word, ">")) {
        return Op.init(.GT, token);
    } else if (streq(token.word, "while")) {
        return Op.init(.WHILE, token);
    } else if (streq(token.word, "do")) {
        return Op.init(.{ .DO = undefined }, token);
    } else if (streq(token.word, "dump")) {
        return Op.init(.DUMP, token);
    } else if (streq(token.word, "mem")) {
        return Op.init(.MEM, token);
    } else if (streq(token.word, ".")) {
        return Op.init(.STORE, token);
    } else if (streq(token.word, ",")) {
        return Op.init(.LOAD, token);
    } else if (streq(token.word, "syscall0")) {
        return Op.init(.SYSCALL0, token);
    } else if (streq(token.word, "syscall1")) {
        return Op.init(.SYSCALL1, token);
    } else if (streq(token.word, "syscall2")) {
        return Op.init(.SYSCALL2, token);
    } else if (streq(token.word, "syscall3")) {
        return Op.init(.SYSCALL3, token);
    } else if (streq(token.word, "syscall4")) {
        return Op.init(.SYSCALL4, token);
    } else if (streq(token.word, "syscall5")) {
        return Op.init(.SYSCALL5, token);
    } else if (streq(token.word, "syscall6")) {
        return Op.init(.SYSCALL6, token);
    } else if (streq(token.word, "2dup")) {
        return Op.init(.DUP2, token);
    } else if (streq(token.word, "swap")) {
        return Op.init(.SWAP, token);
    } else if (streq(token.word, "drop")) {
        return Op.init(.DROP, token);
    } else if (streq(token.word, "<")) {
        return Op.init(.LT, token);
    } else {
        return Op.init(.{ .PUSH = try std.fmt.parseInt(i64, token.word, 10) }, token);
    }
}

fn resolveJumps(program: []Op) !void {
    var stack = std.ArrayList(usize).init(g_a);
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
                        const loc = program[if_ip].loc;
                        std.debug.print(
                            "{s}:{d}:{d}: error: `else` without `if`\n",
                            .{ loc.file_path, loc.row, loc.col },
                        );
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
                        const loc = program[block_ip].loc;
                        std.debug.print(
                            "{s}:{d}:{d}: error: `end` without `if`/`do`\n",
                            .{ loc.file_path, loc.row, loc.col },
                        );
                        return error.Parse;
                    },
                }
            },
            else => {},
        }
    }

    if (stack.items.len > 0) {
        const top = pop(&stack) catch unreachable;
        const loc = program[top].loc;
        std.debug.print(
            "{s}:{d}:{d}: error: unclosed block\n",
            .{ loc.file_path, loc.row, loc.col },
        );
        return error.Parse;
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
    const contents = try std.fs.cwd().readFileAlloc(g_a, path, std.math.maxInt(usize));
    defer g_a.free(contents);
    var lexer = Lexer.init(path, contents);
    var ops = std.ArrayList(Op).init(g_a);
    errdefer ops.deinit();
    while (lexer.next()) |token| {
        try ops.append(try parseTokenAsOp(token));
    }
    var result = try ops.toOwnedSlice();
    errdefer g_a.free(result);
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

pub fn driver(a: std.mem.Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    g_a = a;
    var i: usize = 0;

    temp_path = try temp();
    defer a.free(temp_path);
    temp_dir = try std.fs.cwd().makeOpenPath(temp_path, .{});
    defer temp_dir.close();

    const program_name = common.uncons(args, &i);
    if (args.len < 1) {
        try usage(stderr, program_name);
        std.log.err("no subcommand provided", .{});
        return error.Usage;
    }

    const subcommand = common.uncons(args, &i);
    if (streq(subcommand, "sim")) {
        if (args.len - i < 1) {
            try usage(stderr, program_name);
            std.log.err("no input file provided for simulation", .{});
            return error.Usage;
        }
        const program_path = common.uncons(args, &i);
        const program = try loadProgramFromFile(program_path);
        defer a.free(program);
        try simulateProgram(program, stdout);
    } else if (streq(subcommand, "com")) {
        var do_run = false;
        var maybe_program_path: ?[]const u8 = null;
        var maybe_output_path: ?[]const u8 = null;
        while (args.len - i > 0) {
            const arg = common.uncons(args, &i);
            if (streq(arg, "-r")) {
                do_run = true;
            } else if (streq(arg, "-o")) {
                if (args.len - i == 0) {
                    try usage(stderr, program_name);
                    std.log.err("argument for `-o` not provided", .{});
                    return error.Usage;
                }
                maybe_output_path = common.uncons(args, &i);
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
        _ = try common.runCmd(a, &.{ "nasm", "-f", "elf64", src_path, "-o", obj_path }, .{});
        const exe_path = try std.fs.path.join(a, &.{ basedir, basename });
        defer a.free(exe_path);
        _ = try common.runCmd(a, &.{ "ld", "-o", exe_path, obj_path }, .{});
        if (do_run) {
            return try common.runCmd(a, &.{exe_path}, .{ .stdout = stdout, .fail_ok = true });
        }
    } else if (streq(subcommand, "help")) {
        try usage(stdout, program_name);
        return 0;
    } else {
        try usage(stderr, program_name);
        std.log.err("unknown subcommand '{s}'", .{subcommand});
        return error.Usage;
    }
    return 0;
}

fn run() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const a = gpa.allocator();
    const orig_args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, orig_args);

    return try driver(
        a,
        orig_args,
        std.io.getStdOut().writer(),
        std.io.getStdErr().writer(),
    );
}

pub fn main() void {
    const result = run() catch std.process.exit(1);
    std.process.exit(result);
}
