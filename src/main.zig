const std = @import("std");
const known_folders = @import("known-folders");
const common = @import("common");

const DEBUGGING = .{
    .simulate_program = false,
    .unesc = false,
    .load_program_from_file = false,
};

const Keyword = union(enum) {
    IF: usize,
    ELSE: usize,
    END: usize,
    WHILE,
    DO: usize,
    MACRO,
    INCLUDE,

    const TAG_NAMES = tagNames(@This());

    fn tagName(self: @This()) []const u8 {
        return TAG_NAMES[@enumToInt(std.meta.activeTag(self))];
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{self.tagName()});
        switch (self) {
            .IF,
            .ELSE,
            .END,
            .DO,
            => |x| try writer.print(" {d}", .{x}),
            else => {},
        }
    }
};

fn tagNames(comptime T: type) []const []const u8 {
    var result: []const []const u8 = &[_][]const u8{};
    inline for (std.meta.fieldNames(T)) |fld| {
        var lower_field: [fld.len]u8 = undefined;
        for (fld) |c, i| {
            lower_field[i] = std.ascii.toLower(c);
            if (lower_field[i] == '_') {
                lower_field[i] = ' ';
            }
        }
        result = result ++ [_][]const u8{&lower_field};
    }
    return result;
}

const Op = struct {
    code: Code,
    token: Token,

    pub fn init(code: Code, token: Token) @This() {
        return .{
            .code = code,
            .token = token,
        };
    }

    const Intrinsic = enum {
        PLUS,
        MINUS,
        MUL,
        DIVMOD,
        SHR,
        SHL,
        BOR,
        BAND,
        DUP,
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

        const TAG_NAMES = tagNames(@This());

        fn tagName(self: @This()) []const u8 {
            return TAG_NAMES[@enumToInt(self)];
        }
    };

    const Code = union(enum) {
        PUSH_INT: i64,
        PUSH_STR: []u8,
        INTRINSIC: Intrinsic,
        IF: usize,
        ELSE: usize,
        END: usize,
        WHILE,
        DO: usize,

        const TAG_NAMES = tagNames(@This());

        fn tagName(self: @This()) []const u8 {
            return TAG_NAMES[@enumToInt(std.meta.activeTag(self))];
        }
    };

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.code) {
            .PUSH_INT => |x| try writer.print("{s} {d}", .{ self.code.tagName(), x }),
            .PUSH_STR => |x| {
                const formatter = std.fmt.fmtSliceEscapeUpper(x);
                try writer.print("{s} \"{}\"", .{ self.code.tagName(), formatter });
            },
            .IF,
            .ELSE,
            .END,
            .DO,
            => |x| try writer.print("{s} {d}", .{ self.code.tagName(), x }),
            .INTRINSIC => |i| try writer.print("{s}", .{i.tagName()}),
            .WHILE => try writer.writeAll(self.code.tagName()),
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

const INTRINSIC_NAMES = std.ComptimeStringMap(Op.Intrinsic, .{
    .{ "+", .PLUS },
    .{ "-", .MINUS },
    .{ "*", .MUL },
    .{ "divmod", .DIVMOD },
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
    .{ "dup", .DUP },
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

const KEYWORD_NAMES = std.ComptimeStringMap(Keyword, .{
    .{ "if", .{ .IF = undefined } },
    .{ "end", .{ .END = undefined } },
    .{ "else", .{ .ELSE = undefined } },
    .{ "while", .WHILE },
    .{ "do", .{ .DO = undefined } },
    .{ "macro", .MACRO },
    .{ "include", .INCLUDE },
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
            .INTRINSIC => |i| switch (i) {
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
                .MUL => {
                    const y = try pop(&stack);
                    const x = try pop(&stack);
                    try stack.append(x * y);
                    ip += 1;
                },
                .DIVMOD => {
                    const y = try pop(&stack);
                    const x = try pop(&stack);
                    try stack.append(@divTrunc(x, y));
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
                .DUP => {
                    const x = try pop(&stack);
                    try stack.appendNTimes(x, 2);
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
    const print = @embedFile("dump.asm");
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
            .INTRINSIC => |i| switch (i) {
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
                .MUL => try w.writeAll(
                    \\    pop rbx
                    \\    pop rax
                    \\    mul rbx
                    \\    push rax
                    \\
                ),
                .DIVMOD => try w.writeAll(
                    \\    xor rdx, rdx
                    \\    pop rbx
                    \\    pop rax
                    \\    div rbx
                    \\    push rax
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
                .DUP => try w.writeAll(
                    \\    pop rax
                    \\    push rax
                    \\    push rax
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
            },
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
        char,
        keyword,

        pub fn readableName(self: @This()) []const u8 {
            return switch (self) {
                .word => "a word",
                .int => "an integer",
                .str => "a string",
                .char => "a character",
                .keyword => "a keyword",
            };
        }
    };

    pub const Type = union(Tag) {
        word: []const u8,
        int: i64,
        str: []const u8,
        char: u21,
        keyword: Keyword,
    };

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.type) {
            .word => |value| try writer.print("word {s}", .{value}),
            .int => |value| try writer.print("int {d}", .{value}),
            .str => |value| try writer.print("str {s}", .{value}),
            .char => |value| {
                var utf8buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(value, &utf8buf) catch unreachable;
                try writer.print("char {s}", .{utf8buf[0..len]});
            },
            .keyword => |value| try writer.print("{}", .{value}),
        }
    }
};

const UnescOptions = struct {
    require_one_codepoint: bool = false,
};

fn unesc(loc: Location, s: []const u8, options: UnescOptions) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(g_a, s.len);
    errdefer result.deinit();
    var i: usize = 0;
    var codepoints: usize = 0;
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
                .{loc.colOffset(i)},
            );
            return error.Parse;
        }
        switch (s[i]) {
            '\\' => {
                codepoints += 1;
                try result.append('\\');
            },
            '\'' => {
                codepoints += 1;
                try result.append('\'');
            },
            '"' => {
                codepoints += 1;
                try result.append('"');
            },
            // backspace
            'b' => {
                codepoints += 1;
                try result.append('\x08');
            },
            // form feed
            'f' => {
                codepoints += 1;
                try result.append('\x0C');
            },
            // tab
            't' => {
                codepoints += 1;
                try result.append('\t');
            },
            // newline
            'n' => {
                codepoints += 1;
                try result.append('\n');
            },
            // CR
            'r' => {
                codepoints += 1;
                try result.append('\r');
            },
            // vertical tab
            'v' => {
                codepoints += 1;
                try result.append('\x0B');
            },
            // BEL
            'a' => {
                codepoints += 1;
                try result.append('\x07');
            },
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
                        .{ loc.colOffset(i), char_val },
                    );
                    return error.Parse;
                }
                codepoints += 1;
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
                        loc: Location,
                        count: usize,
                        first: u8,
                        start: usize,
                        j: usize,

                        fn printErr(self: @This()) error{Parse} {
                            std.debug.print(
                                "{}: expected {d} hex digits after \\{c}, got only {d}\n",
                                .{
                                    self.loc.colOffset(self.start),
                                    self.count,
                                    self.first,
                                    self.j,
                                },
                            );
                            return error.Parse;
                        }
                    }{ .loc = loc, .count = count, .first = first, .start = start, .j = j };

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
                        .{ loc.colOffset(start), first, char_val },
                    );
                    return error.Parse;
                }
                codepoints += 1;
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
                    .{ loc.colOffset(i), s[i] },
                );
                return error.Parse;
            },
        }
    }
    if (options.require_one_codepoint and codepoints > 1) {
        std.debug.print("{}: expected one codepoint, got {d}\n", .{ loc, codepoints });
        return error.Parse;
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

    pub fn init(file_path: []const u8, source: []const u8) @This() {
        var lines = std.mem.split(u8, source, &.{'\n'});
        return .{
            .file_path = file_path,
            .source = source,
            .line = lines.first(),
            .lines = lines,
        };
    }

    fn lexWord(text: []const u8) Token.Type {
        if (std.fmt.parseInt(i64, text, 10)) |i| {
            return .{ .int = i };
        } else |_| if (KEYWORD_NAMES.get(text)) |kw| {
            return .{ .keyword = kw };
        } else {
            return .{ .word = text };
        }
    }

    fn findTerminatingQuote(self: @This(), start: usize, quote: u8) ?usize {
        var pos = start;
        while (std.mem.indexOfScalarPos(u8, self.line, pos, quote)) |i| {
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
                switch (self.line[col]) {
                    '"' => {
                        const col_end = self.findTerminatingQuote(col + 1, '"') orelse {
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
                    },
                    '\'' => {
                        const col_end = self.findTerminatingQuote(col + 1, '\'') orelse {
                            std.debug.print(
                                "{s}:{d}:{d}: error: unclosed character literal\n",
                                .{ self.file_path, self.row + 1, self.col + 1 },
                            );
                            return error.Lex;
                        };
                        const text = try unesc(
                            .{
                                .file_path = self.file_path,
                                .row = self.row + 1,
                                .col = col,
                            },
                            self.line[col + 1 .. col_end],
                            .{ .require_one_codepoint = true },
                        );
                        defer g_a.free(text);
                        self.col = col_end + 1;
                        return Token{
                            .loc = .{
                                .file_path = self.file_path,
                                .row = self.row + 1,
                                .col = col,
                            },
                            .type = .{
                                .char = std.unicode.utf8Decode(text) catch unreachable,
                            },
                        };
                    },
                    else => {
                        const col_end = std.mem.indexOfAnyPos(u8, self.line, col, &std.ascii.whitespace) orelse self.line.len;
                        const text = self.line[col..col_end];
                        if (std.mem.startsWith(u8, text, "//")) {
                            self.line = "";
                            continue;
                        }
                        const result = Token{
                            .loc = .{
                                .file_path = self.file_path,
                                .row = self.row + 1,
                                .col = col + 1,
                            },
                            .type = lexWord(text),
                        };
                        self.col = col_end;
                        return result;
                    },
                }
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

fn loadProgramFromFile(path: []const u8, include_paths: []const []const u8) ![]Op {
    const contents = try std.fs.cwd().readFileAlloc(g_a, path, std.math.maxInt(usize));
    var extra_contents = std.ArrayList([]const u8).init(g_a);
    defer {
        for (extra_contents.items) |text| {
            g_a.free(text);
        }
        extra_contents.deinit();
    }
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
            std.debug.print("{}: @{d}: {}\n", .{ op.token.loc, i, op });
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
            std.debug.print("{}: ip {d}, {}\n", .{ token.loc, ip, token });

        switch (token.type) {
            .word => |value| if (INTRINSIC_NAMES.get(value)) |code| {
                try program.append(Op.init(.{ .INTRINSIC = code }, token));
                ip += 1;
            } else if (macros.get(value)) |macro| {
                if (DEBUGGING.load_program_from_file)
                    std.debug.print("... is a macro of length {d}\n", .{macro.tokens.items.len});
                try tokens.appendSlice(macro.tokens.items);
                // do not process any further
                continue;
            } else {
                std.debug.print("{}: unknown word `{s}`\n", .{ token.loc, value });
                return error.Parse;
            },
            .int => |value| {
                try program.append(Op.init(.{ .PUSH_INT = value }, token));
                ip += 1;
            },
            .str => |value| {
                try program.append(
                    Op.init(.{ .PUSH_STR = try unesc(token.loc, value, .{}) }, token),
                );
                ip += 1;
            },
            .char => |value| {
                try program.append(Op.init(.{ .PUSH_INT = value }, token));
                ip += 1;
            },
            .keyword => |*kw| switch (kw.*) {
                .IF => {
                    try stack.append(ip);
                    try program.append(Op.init(.{ .IF = undefined }, token));
                    ip += 1;
                },
                .WHILE => {
                    try stack.append(ip);
                    try program.append(Op.init(.WHILE, token));
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
                            if (DEBUGGING.load_program_from_file)
                                std.debug.print("instead got {any}\n", .{program.items[if_ip].code});
                            return error.Parse;
                        },
                    }
                    try program.append(Op.init(.{ .ELSE = undefined }, token));
                    ip += 1;
                },
                .DO => |*dest| {
                    const while_ip = try pop(&stack);
                    dest.* = while_ip;
                    try stack.append(ip);
                    try program.append(Op.init(.{ .DO = dest.* }, token));
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
                            if (DEBUGGING.load_program_from_file)
                                std.debug.print(
                                    "instead got {any} @{d}\n",
                                    .{ program.items[block_ip].code, block_ip },
                                );
                            return error.Parse;
                        },
                    }
                    try program.append(Op.init(.{ .END = end_dest.* }, token));
                    ip += 1;
                },
                .INCLUDE => {
                    if (tokens.items.len == 0) {
                        std.debug.print(
                            "{}: error: expected include file path, got EOF\n",
                            .{token.loc},
                        );
                        return error.Parse;
                    }
                    token = tokens.pop();
                    if (DEBUGGING.load_program_from_file)
                        std.debug.print("{}: ip {d}, {}\n", .{ token.loc, ip, token });
                    const include_path = switch (token.type) {
                        .str => |value| value,
                        else => {
                            std.debug.print(
                                "{}: error: expected include path to be {s}, got {s}\n",
                                .{
                                    token.loc,
                                    Token.Tag.readableName(.str),
                                    std.meta.activeTag(token.type).readableName(),
                                },
                            );
                            return error.Parse;
                        },
                    };
                    const IncludedFile = struct {
                        full_path: []const u8,
                        contents: []const u8,
                    };
                    const included_contents = findInclude: {
                        for (include_paths) |incdir| {
                            const tryReadRelative = struct {
                                fn f(relative: []const u8, incpath: []const u8) !struct {
                                    dir: std.fs.Dir,
                                    contents: []const u8,
                                } {
                                    const dir = try std.fs.cwd().openDir(relative, .{});
                                    const read_result = try dir.readFileAlloc(g_a, incpath, std.math.maxInt(usize));
                                    return .{ .dir = dir, .contents = read_result };
                                }
                            }.f;
                            const included_contents = tryReadRelative(incdir, include_path) catch |e| switch (e) {
                                error.FileNotFound => continue,
                                else => return e,
                            };
                            break :findInclude IncludedFile{
                                .full_path = try included_contents.dir.realpathAlloc(g_a, include_path),
                                .contents = included_contents.contents,
                            };
                        }
                        std.debug.print(
                            "{}: error: file `{s}` not found\n",
                            .{ token.loc, include_path },
                        );
                        return error.Parse;
                    };
                    try extra_contents.appendSlice(&.{ included_contents.full_path, included_contents.contents });
                    var include_lexer = Lexer.init(included_contents.full_path, included_contents.contents);
                    const include_start = tokens.items.len;
                    while (try include_lexer.next()) |include_token| {
                        try tokens.append(include_token);
                    }
                    std.mem.reverse(Token, tokens.items[include_start..]);
                },
                .MACRO => {
                    if (tokens.items.len == 0) {
                        std.debug.print(
                            "{}: error: expected macro name, got EOF\n",
                            .{token.loc},
                        );
                        return error.Parse;
                    }
                    token = tokens.pop();
                    if (DEBUGGING.load_program_from_file)
                        std.debug.print("{}: ip {d}, {}\n", .{ token.loc, ip, token });
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
                    if (INTRINSIC_NAMES.get(value) != null) {
                        std.debug.print(
                            "{}: error: redefinition of intrinsic word `{s}`." ++
                                "Please choose a different name for your macro.\n",
                            .{ token.loc, value },
                        );
                        return error.Parse;
                    }
                    var macro = Macro.init(token.loc);

                    findEnd: {
                        while (tokens.popOrNull()) |definition_token| {
                            if (DEBUGGING.load_program_from_file)
                                std.debug.print(
                                    "{}: ip {d}, {}\n",
                                    .{ definition_token.loc, ip, definition_token },
                                );
                            switch (definition_token.type) {
                                .keyword => |temp_kw| if (temp_kw == .END) {
                                    break :findEnd;
                                },
                                else => {},
                            }
                            try macro.tokens.append(definition_token);
                        }

                        std.debug.print(
                            "{}: error: expected `end` after macro definition, got EOF\n",
                            .{token.loc},
                        );
                        return error.Parse;
                    }
                    std.mem.reverse(Token, macro.tokens.items);
                    try macros.put(value, macro);
                },
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
    if (DEBUGGING.load_program_from_file) {
        std.debug.print("INSTRUCTIONS:\n", .{});
        for (result) |op, i| {
            std.debug.print("{}: @{d}: {}\n", .{ op.token.loc, i, op });
        }
    }
    return result;
}

fn usage(writer: anytype, program_name: []const u8) !void {
    try writer.print(
        \\Usage: {s} [OPTIONS] <SUBCOMMAND> [ARGS]
        \\  OPTIONS:
        \\    -I <path>                  Add a folder to the include path
        \\  SUBCOMMANDS:
        \\    sim <file>                 Simulate the program
        \\    com [OPTIONS] <file>       Compile the program
        \\      OPTIONS:
        \\        -r                       Run the program after compilation
        \\        -o <file|dir>            Set the output path
        \\        -s                       Silent; don't print compilation phase info
        \\    help                       Print this help to stdout
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

    var include_paths = std.ArrayList([]const u8).init(a);
    defer include_paths.deinit();
    try include_paths.appendSlice(&.{ ".", "./lib" });
    while (args.len - i > 0) {
        if (streq(args[i], "-I")) {
            if (args.len - i == 0) {
                try usage(stderr, program_name);
                std.log.err("argument for `-I` not provided", .{});
                return error.Usage;
            }
            try include_paths.append(common.uncons(args, &i));
        } else {
            break;
        }
    }

    const subcommand = common.uncons(args, &i);
    if (streq(subcommand, "sim")) {
        if (args.len - i < 1) {
            try usage(stderr, program_name);
            std.log.err("no input file provided for simulation", .{});
            return error.Usage;
        }
        const program_path = common.uncons(args, &i);
        const program = try loadProgramFromFile(program_path, include_paths.items);
        defer {
            for (program) |op| {
                op.deinit();
            }
            a.free(program);
        }
        try simulateProgram(program, stdout);
    } else if (streq(subcommand, "com")) {
        var do_run = false;
        var silent = false;
        var maybe_program_path: ?[]const u8 = null;
        var maybe_output_path: ?[]const u8 = null;
        while (args.len - i > 0) {
            const arg = common.uncons(args, &i);
            if (streq(arg, "-r")) {
                do_run = true;
            } else if (streq(arg, "-s")) {
                silent = true;
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
        const program = try loadProgramFromFile(program_path, include_paths.items);
        defer {
            for (program) |op| {
                op.deinit();
            }
            a.free(program);
        }
        var basename = std.fs.path.basename(program_path);
        const extension = std.fs.path.extension(basename);
        if (streq(extension, ".porth")) {
            basename = basename[0 .. basename.len - ".porth".len];
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
        const src_path = try std.fs.path.join(a, &.{ temp_path, "output.asm" });
        defer a.free(src_path);
        if (!silent)
            std.log.info("Generating {s}", .{src_path});
        try compileProgram(program, src_path);
        const obj_path = try std.fs.path.join(a, &.{ temp_path, "output.o" });
        defer a.free(obj_path);
        _ = try common.runCmd(
            a,
            &.{ "nasm", "-f", "elf64", "-gdwarf", src_path, "-o", obj_path },
            .{ .silent = silent },
        );
        const exe_path = try std.fs.path.join(a, &.{ basedir, basename });
        defer a.free(exe_path);
        _ = try common.runCmd(
            a,
            &.{ "ld", "-o", exe_path, obj_path },
            .{ .silent = silent },
        );
        if (do_run) {
            return try common.runCmd(
                a,
                &.{exe_path},
                .{ .stdout = stdout, .fail_ok = true, .silent = silent },
            );
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
