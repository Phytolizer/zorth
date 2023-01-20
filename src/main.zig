const std = @import("std");
const known_folders = @import("known-folders");
const common = @import("common.zig");

const DEBUGGING = .{
    .simulate_program = false,
    .unesc = false,
    .load_program_from_file = false,
};

const Op = struct {
    code: Code,
    token: Token,

    pub fn init(code: Code, token: Token) @This() {
        return .{
            .code = code,
            .token = token,
        };
    }

    const Code = union(enum) {
        PUSH_INT: i64,
        PUSH_STR: []u8,
        PLUS,
        MINUS,
        MOD,
        SHR,
        SHL,
        BOR,
        BAND,
        IF: usize,
        ELSE: usize,
        END: usize,
        WHILE,
        DO: usize,
        MACRO,
        DUP,
        DUP2,
        SWAP,
        DROP,
        OVER,
        EQ,
        NE,
        GT,
        LT,
        GE,
        LE,
        MEM,
        LOAD,
        STORE,
        PRINT,
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
                var lower_field: [fld.len]u8 = undefined;
                for (fld) |c, i| {
                    lower_field[i] = std.ascii.toLower(c);
                    if (lower_field[i] == '_') {
                        lower_field[i] = ' ';
                    }
                }
                result = result ++ [_][]const u8{&lower_field};
            }
            break :init result;
        };

        fn tagName(self: @This()) []const u8 {
            return TAG_NAMES[@enumToInt(std.meta.activeTag(self))];
        }
    };

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.code) {
            .PUSH_INT => |x| try writer.print("{s} {d}", .{ Code.tagName(self.code), x }),
            else => try writer.writeAll(Code.tagName(self.code)),
        }
    }
    const COUNT_OPS = @typeInfo(Op).Union.fields.len;

    pub fn deinit(self: @This()) void {
        switch (self.code) {
            .PUSH_STR => |s| {
                g_a.free(s);
            },
            else => {},
        }
    }
};

const STR_CAPACITY = 640_000;
const MEM_CAPACITY = 640_000;

const BUILTIN_WORDS = std.ComptimeStringMap(Op.Code, .{
    .{ "+", .PLUS },
    .{ "-", .MINUS },
    .{ "mod", .MOD },
    .{ "print", .PRINT },
    .{ "=", .EQ },
    .{ ">", .GT },
    .{ "<", .LT },
    .{ ">=", .GE },
    .{ "<=", .LE },
    .{ "!=", .NE },
    .{ "shr", .SHR },
    .{ "shl", .SHL },
    .{ "bor", .BOR },
    .{ "band", .BAND },
    .{ "if", .{ .IF = undefined } },
    .{ "end", .{ .END = undefined } },
    .{ "else", .{ .ELSE = undefined } },
    .{ "while", .WHILE },
    .{ "do", .{ .DO = undefined } },
    .{ "macro", .MACRO },
    .{ "dup", .DUP },
    .{ "2dup", .DUP2 },
    .{ "swap", .SWAP },
    .{ "drop", .DROP },
    .{ "over", .OVER },
    .{ "mem", .MEM },
    .{ ".", .STORE },
    .{ ",", .LOAD },
    .{ "syscall0", .SYSCALL0 },
    .{ "syscall1", .SYSCALL1 },
    .{ "syscall2", .SYSCALL2 },
    .{ "syscall3", .SYSCALL3 },
    .{ "syscall4", .SYSCALL4 },
    .{ "syscall5", .SYSCALL5 },
    .{ "syscall6", .SYSCALL6 },
});

var g_a: std.mem.Allocator = undefined;

fn notImplemented() noreturn {
    std.log.err("not implemented", .{});
    unreachable;
}

const Macro = struct {
    loc: Location,
    tokens: std.ArrayList(Token),

    pub fn init(loc: Location) @This() {
        return .{
            .loc = loc,
            .tokens = std.ArrayList(Token).init(g_a),
        };
    }

    pub fn deinit(self: @This()) void {
        self.tokens.deinit();
    }
};

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

fn simulateProgram(program: []Op, stdout: anytype) !void {
    var stack = std.ArrayList(i64).init(g_a);
    defer stack.deinit();
    var ip: usize = 0;
    var mem = try g_a.alloc(u8, STR_CAPACITY + MEM_CAPACITY);
    var str_offsets = std.AutoHashMap(usize, usize).init(g_a);
    defer str_offsets.deinit();
    var str_size: usize = 0;
    defer g_a.free(mem);
    while (ip < program.len) {
        const op = &program[ip];
        if (DEBUGGING.simulate_program) {
            std.debug.print("stack: {any}\n", .{stack.items});
            std.debug.print("op: {}\n", .{op});
        }
        switch (op.code) {
            .PUSH_INT => |x| {
                try stack.append(x);
                ip += 1;
            },
            .PUSH_STR => |s| {
                try stack.append(@intCast(i64, s.len));
                if (str_offsets.get(ip)) |offset| {
                    try stack.append(@intCast(i64, offset));
                } else {
                    const offset = str_size;
                    try str_offsets.put(ip, offset);
                    std.mem.copy(u8, mem[str_size .. str_size + s.len], s);
                    str_size += s.len;
                    try stack.append(@intCast(i64, offset));
                }
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
            .MOD => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@rem(x, y));
                ip += 1;
            },
            .SHR => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(if (y > std.math.maxInt(u6))
                    0
                else
                    x >> @intCast(u6, y));
                ip += 1;
            },
            .SHL => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(if (y > std.math.maxInt(u6))
                    0
                else
                    x << @intCast(u6, y));
                ip += 1;
            },
            .BOR => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x | y);
                ip += 1;
            },
            .BAND => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(x & y);
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
            // this is a compile-time word
            .MACRO => unreachable,
            .DUP => {
                const x = try pop(&stack);
                try stack.appendNTimes(x, 2);
                ip += 1;
            },
            .DUP2 => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.appendSlice(&.{ x, y, x, y });
                ip += 1;
            },
            .SWAP => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.appendSlice(&.{ y, x });
                ip += 1;
            },
            .DROP => {
                _ = try pop(&stack);
                ip += 1;
            },
            .OVER => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.appendSlice(&.{ x, y, x });
                ip += 1;
            },
            .EQ => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x == y));
                ip += 1;
            },
            .NE => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x != y));
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
            .GE => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x >= y));
                ip += 1;
            },
            .LE => {
                const y = try pop(&stack);
                const x = try pop(&stack);
                try stack.append(@boolToInt(x <= y));
                ip += 1;
            },
            .MEM => {
                try stack.append(STR_CAPACITY);
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
            .PRINT => {
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
                        try stack.append(@intCast(i64, count));
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
    const print = @embedFile("dump.nasm");
    var temp_nasm = try temp_dir.createFile(out_path, .{});
    defer temp_nasm.close();
    var strs = std.ArrayList([]const u8).init(g_a);
    defer strs.deinit();

    const w = temp_nasm.writer();
    try w.writeAll(print);
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
            .PUSH_INT => |x| try w.print(
                \\    mov rax, {d}
                \\    push rax
                \\
            , .{x}),
            .PUSH_STR => |s| {
                try w.print(
                    \\    mov rax, {d}
                    \\    push rax
                    \\    push zorth_str_{d}
                    \\
                , .{ s.len, strs.items.len });
                try strs.append(s);
            },
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
            .MOD => try w.writeAll(
                \\    xor rdx, rdx
                \\    pop rbx
                \\    pop rax
                \\    div rbx
                \\    push rdx
                \\
            ),
            .SHR => try w.writeAll(
                \\    pop rcx
                \\    pop rbx
                \\    shr rbx, cl
                \\    push rbx
                \\
            ),
            .SHL => try w.writeAll(
                \\    pop rcx
                \\    pop rbx
                \\    shl rbx, cl
                \\    push rbx
                \\
            ),
            .BOR => try w.writeAll(
                \\    pop rbx
                \\    pop rax
                \\    or rax, rbx
                \\    push rax
                \\
            ),
            .BAND => try w.writeAll(
                \\    pop rbx
                \\    pop rax
                \\    and rax, rbx
                \\    push rax
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
            .WHILE => {},
            .DO => |dest| try w.print(
                \\    pop rax
                \\    test rax, rax
                \\    jz .zorth_addr_{d}
                \\
            , .{dest}),
            // this is a compile-time word
            .MACRO => unreachable,
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
            .OVER => try w.writeAll(
                \\    pop rbx
                \\    pop rax
                \\    push rax
                \\    push rbx
                \\    push rax
                \\
            ),
            .EQ => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmove rcx, rdx
                \\    push rcx
                \\
            ),
            .NE => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmovne rcx, rdx
                \\    push rcx
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
            .GE => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmovge rcx, rdx
                \\    push rcx
                \\
            ),
            .LE => try w.writeAll(
                \\    mov rcx, 0
                \\    mov rdx, 1
                \\    pop rbx
                \\    pop rax
                \\    cmp rax, rbx
                \\    cmovle rcx, rdx
                \\    push rcx
                \\
            ),
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
            .PRINT => try w.writeAll(
                \\    pop rdi
                \\    call dump
                \\
            ),
            .SYSCALL0 => try w.writeAll(
                \\    pop rax
                \\    syscall
                \\    push rax
                \\
            ),
            .SYSCALL1 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    syscall
                \\    push rax
                \\
            ),
            .SYSCALL2 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    syscall
                \\    push rax
                \\
            ),
            .SYSCALL3 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    pop rdx
                \\    syscall
                \\    push rax
                \\
            ),
            .SYSCALL4 => try w.writeAll(
                \\    pop rax
                \\    pop rdi
                \\    pop rsi
                \\    pop rdx
                \\    pop r10
                \\    syscall
                \\    push rax
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
                \\    push rax
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
                \\    push rax
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
        \\    section .data
        \\
    , .{ program.len, MEM_CAPACITY });
    for (strs.items) |s, i| {
        try w.print("zorth_str_{d}: db ", .{i});
        for (s) |b, j| {
            try w.print("{s}{d}", .{ if (j > 0) "," else "", b });
        }
        try w.writeAll("\n");
    }
}

const Location = struct {
    file_path: []const u8,
    row: usize,
    col: usize,

    pub fn colOffset(self: @This(), offset: usize) @This() {
        return .{
            .file_path = self.file_path,
            .row = self.row,
            .col = self.col + offset,
        };
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}", .{ self.file_path, self.row, self.col });
    }
};

const Token = struct {
    loc: Location,
    type: Type,

    pub const Tag = enum {
        word,
        int,
        str,

        pub fn readableName(self: @This()) []const u8 {
            return switch (self) {
                .word => "word",
                .int => "integer",
                .str => "string",
            };
        }
    };

    pub const Type = union(Tag) {
        word: []const u8,
        int: i64,
        str: []const u8,
    };
};

// TODO: error handling
fn unesc(token: Token, s: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(g_a, s.len);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try result.append(s[i]);
            continue;
        }

        i += 1;
        if (i == s.len) {
            // early EOS, error
            std.debug.print(
                "{}: escape at end of string\n",
                .{token.loc.colOffset(i)},
            );
            return error.Parse;
        }
        switch (s[i]) {
            '\\' => try result.append('\\'),
            '\'' => try result.append('\''),
            '"' => try result.append('"'),
            // backspace
            'b' => try result.append('\x08'),
            // form feed
            'f' => try result.append('\x0C'),
            // tab
            't' => try result.append('\t'),
            // newline
            'n' => try result.append('\n'),
            // CR
            'r' => try result.append('\r'),
            // vertical tab
            'v' => try result.append('\x0B'),
            // BEL
            'a' => try result.append('\x07'),
            // octal escape
            '0'...'7' => {
                var char_val = @as(usize, s[i] - '0');
                comptime var j = 0;
                if (DEBUGGING.unesc)
                    std.debug.print("Decoding octal escape sequence '{c}'\n", .{s[i]});
                inline while (j < 2) : (j += 1) {
                    i += 1;
                    if (i < s.len and s[i] >= '0' and s[i] <= '7') {
                        if (DEBUGGING.unesc)
                            std.debug.print("Char '{c}' is valid\n", .{s[i]});
                        char_val = (char_val << 3) + @intCast(u6, s[i] - '0');
                    }
                }
                if (DEBUGGING.unesc)
                    std.debug.print("Result: {d}\n", .{char_val});
                if (char_val > 0o377) {
                    // invalid octal escape
                    std.debug.print(
                        "{}: invalid octal escape '\\{o}'\n",
                        .{ token.loc.colOffset(i), char_val },
                    );
                    return error.Parse;
                }
                try result.append(@intCast(u8, char_val));
            },
            // hex-style escape
            'x', 'u', 'U' => {
                const first = s[i];
                const count: usize = switch (first) {
                    'x' => 2,
                    'u' => 4,
                    'U' => 8,
                    else => unreachable,
                };
                if (DEBUGGING.unesc)
                    std.debug.print("Decoding escape sequence '{c}'\n", .{first});
                var char_val: usize = 0;
                var j: usize = 0;
                const start = i;
                while (j < count) : (j += 1) {
                    i += 1;
                    const messager = struct {
                        token: Token,
                        count: usize,
                        first: u8,
                        start: usize,
                        j: usize,

                        fn printErr(self: @This()) error{Parse} {
                            std.debug.print(
                                "{}: expected {d} hex digits after \\{c}, got only {d}\n",
                                .{
                                    self.token.loc.colOffset(self.start),
                                    self.count,
                                    self.first,
                                    self.j,
                                },
                            );
                            return error.Parse;
                        }
                    }{ .token = token, .count = count, .first = first, .start = start, .j = j };

                    if (i == s.len) {
                        return messager.printErr();
                    }
                    const increment = switch (s[i]) {
                        '0'...'9' => s[i] - '0',
                        'a'...'f' => s[i] - 'a' + 10,
                        'A'...'F' => s[i] - 'A' + 10,
                        else => return messager.printErr(),
                    };
                    char_val <<= 4;
                    char_val += increment;
                    if (DEBUGGING.unesc)
                        std.debug.print("'{c}' -> {d}\n", .{ s[i], increment });
                }
                if (DEBUGGING.unesc)
                    std.debug.print("result: {d} ({x})\n", .{ char_val, char_val });
                if (char_val > std.math.maxInt(u21)) {
                    std.debug.print(
                        "{}: escape '\\{c}{x}' is too big for Unicode\n",
                        .{ token.loc.colOffset(start), first, char_val },
                    );
                    return error.Parse;
                }
                // codepoint goes back to utf8
                var encoded_val: [4]u8 = undefined;
                const num_bytes = try std.unicode.utf8Encode(@intCast(u21, char_val), &encoded_val);
                if (DEBUGGING.unesc)
                    std.debug.print("as unicode: '{s}'\n", .{encoded_val[0..num_bytes]});
                try result.appendSlice(encoded_val[0..num_bytes]);
            },
            else => {
                std.debug.print(
                    "{}: unsupported escape '\\{c}'\n",
                    .{ token.loc.colOffset(i), s[i] },
                );
                return error.Parse;
            },
        }
    }
    return try result.toOwnedSlice();
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

    fn lexWord(text: []const u8) Token.Type {
        if (std.fmt.parseInt(i64, text, 10)) |i| {
            return .{ .int = i };
        } else |_| {
            return .{ .word = text };
        }
    }

    fn findTerminatingQuote(self: @This(), start: usize) ?usize {
        var pos = start;
        while (std.mem.indexOfScalarPos(u8, self.line, pos, '"')) |i| {
            // skip escaped quotes
            if (self.line[i - 1] == '\\') {
                pos = i + 1;
                continue;
            }
            return i;
        }
        return null;
    }

    pub fn next(self: *@This()) !?Token {
        while (true) {
            const maybe_col = indexOfNonePos(u8, self.line, self.col, &std.ascii.whitespace);
            if (maybe_col) |col| {
                if (self.line[col] == '"') {
                    const col_end = self.findTerminatingQuote(col + 1) orelse {
                        std.debug.print(
                            "{s}:{d}:{d}: error: unclosed string literal\n",
                            .{ self.file_path, self.row + 1, self.col + 1 },
                        );
                        return error.Lex;
                    };
                    const text = self.line[col + 1 .. col_end];
                    self.col = col_end + 1;
                    return Token{
                        .loc = .{
                            .file_path = self.file_path,
                            .row = self.row + 1,
                            .col = col + 1,
                        },
                        .type = .{ .str = text },
                    };
                } else {
                    const col_end = std.mem.indexOfAnyPos(u8, self.line, col, &std.ascii.whitespace) orelse self.line.len;
                    const result = Token{
                        .loc = .{
                            .file_path = self.file_path,
                            .row = self.row + 1,
                            .col = col + 1,
                        },
                        .type = lexWord(self.line[col..col_end]),
                    };
                    self.col = col_end;
                    return result;
                }
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
    var program = std.ArrayList(Op).init(g_a);
    errdefer program.deinit();
    var tokens = std.ArrayList(Token).init(g_a);
    defer tokens.deinit();
    while (try lexer.next()) |token| {
        try tokens.append(token);
    }
    var macros = std.StringHashMap(Macro).init(g_a);
    defer {
        var it = macros.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        macros.deinit();
    }
    var stack = std.ArrayList(usize).init(g_a);
    defer stack.deinit();
    errdefer |e| if (e == error.Parse and DEBUGGING.load_program_from_file) {
        std.debug.print("INSTRUCTIONS SO FAR:\n", .{});
        for (program.items) |op, i| {
            std.debug.print("{}: @{d}: {any}\n", .{ op.token.loc, i, op.code });
        }
        std.debug.print("BLOCK STACK:\n", .{});
        for (stack.items) |item| {
            std.debug.print("{any}\n", .{program.items[item].code});
        }
    };
    std.mem.reverse(Token, tokens.items);
    var ip: usize = 0;
    while (tokens.items.len > 0) {
        var token = tokens.pop();
        if (DEBUGGING.load_program_from_file)
            std.debug.print("{}: ip {d}, token {any}\n", .{ token.loc, ip, token.type });

        var op = switch (token.type) {
            .word => |value| if (BUILTIN_WORDS.get(value)) |code|
                Op.init(code, token)
            else if (macros.get(value)) |macro| {
                std.mem.reverse(Token, macro.tokens.items);
                try tokens.appendSlice(macro.tokens.items);
                // do not process any further
                continue;
            } else {
                std.debug.print("{}: unknown word `{s}`\n", .{ token.loc, value });
                return error.Parse;
            },
            .int => |value| Op.init(.{ .PUSH_INT = value }, token),
            .str => |value| Op.init(.{ .PUSH_STR = try unesc(token, value) }, token),
        };
        switch (op.code) {
            .IF, .WHILE => {
                try stack.append(ip);
                try program.append(op);
                ip += 1;
            },
            .ELSE => {
                const if_ip = try pop(&stack);
                switch (program.items[if_ip].code) {
                    .IF => |*dest| {
                        dest.* = ip + 1;
                        try stack.append(ip);
                    },
                    else => {
                        std.debug.print(
                            "{}: error: `else` without `if`\n",
                            .{program.items[if_ip].token.loc},
                        );
                        return error.Parse;
                    },
                }
                try program.append(op);
                ip += 1;
            },
            .DO => |*dest| {
                const while_ip = try pop(&stack);
                dest.* = while_ip;
                try stack.append(ip);
                try program.append(op);
                ip += 1;
            },
            .END => |*end_dest| {
                const block_ip = try pop(&stack);
                switch (program.items[block_ip].code) {
                    .IF, .ELSE => |*dest| {
                        dest.* = ip;
                        end_dest.* = ip + 1;
                    },
                    .DO => |*dest| {
                        end_dest.* = dest.*;
                        dest.* = ip + 1;
                    },
                    else => {
                        std.debug.print(
                            "{}: error: `end` without `if`/`do`\n",
                            .{program.items[block_ip].token.loc},
                        );
                        return error.Parse;
                    },
                }
                try program.append(op);
                ip += 1;
            },
            .MACRO => {
                if (tokens.items.len == 0) {
                    std.debug.print(
                        "{}: error: expected macro name, got EOF\n",
                        .{op.token.loc},
                    );
                    return error.Parse;
                }
                token = tokens.pop();
                const value = switch (token.type) {
                    .word => |value| value,
                    else => {
                        std.debug.print(
                            "{}: error: expected macro name to be {s}, got {s}\n",
                            .{
                                token.loc,
                                Token.Tag.readableName(.word),
                                std.meta.activeTag(token.type).readableName(),
                            },
                        );
                        return error.Parse;
                    },
                };
                if (macros.get(value)) |existing| {
                    std.debug.print(
                        "{}: error: redefinition of existing macro `{s}`\n",
                        .{ token.loc, value },
                    );
                    std.debug.print(
                        "{}: note: first definition is here\n",
                        .{existing.loc},
                    );
                    return error.Parse;
                }
                if (BUILTIN_WORDS.get(value) != null) {
                    std.debug.print(
                        "{}: error: redefinition of built-in word `{s}`\n",
                        .{ token.loc, value },
                    );
                    return error.Parse;
                }
                var macro = Macro.init(op.token.loc);

                findEnd: {
                    while (tokens.popOrNull()) |definition_token| {
                        switch (definition_token.type) {
                            .word => |tvalue| if (streq(tvalue, "end")) {
                                break :findEnd;
                            },
                            else => {},
                        }
                        try macro.tokens.append(definition_token);
                    }

                    std.debug.print(
                        "{}: error: expected `end` after macro definition, got EOF\n",
                        .{op.token.loc},
                    );
                    return error.Parse;
                }
                try macros.put(value, macro);
            },
            else => {
                try program.append(op);
                ip += 1;
            },
        }
    }

    if (stack.items.len > 0) {
        const top = pop(&stack) catch unreachable;
        const token = program.items[top].token;
        std.debug.print(
            "{}: error: unclosed block\n",
            .{token.loc},
        );
        return error.Parse;
    }
    const result = try program.toOwnedSlice();
    if (DEBUGGING.load_program_from_file)
        for (result) |op, i| {
            std.debug.print("{d:>2}: {any}\n", .{ i, op.code });
        };
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
        defer {
            for (program) |op| {
                op.deinit();
            }
            a.free(program);
        }
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
        defer {
            for (program) |op| {
                op.deinit();
            }
            a.free(program);
        }
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
        _ = try common.runCmd(a, &.{ "nasm", "-f", "elf64", "-gdwarf", src_path, "-o", obj_path }, .{});
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
