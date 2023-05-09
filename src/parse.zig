const std = @import("std");
const Op = @import("Op.zig");
const Program = @import("Program.zig");

const ParseError = error{Parse};

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Token = struct {
    loc: Op.Location,
    value: Value,

    const Value = union(enum) {
        word: []const u8,
        int: u63,
        str: []const u8,

        pub const Tag = std.meta.Tag(@This());
        pub fn tagReadableName(tag: Tag) []const u8 {
            return switch (tag) {
                .word => "word",
                .int => "integer",
                .str => "string",
            };
        }
        pub fn humanReadableName(self: @This()) []const u8 {
            return tagReadableName(std.meta.activeTag(self));
        }
    };
};

const builtin_words = std.ComptimeStringMap(Op.Code, .{
    .{ "+", .plus },
    .{ "-", .minus },
    .{ "mod", .mod },
    .{ "shr", .shr },
    .{ "shl", .shl },
    .{ "bor", .bor },
    .{ "band", .band },
    .{ "print", .print },
    .{ "mem", .mem },
    .{ ",", .load },
    .{ ".", .store },
    .{ "syscall0", .syscall0 },
    .{ "syscall1", .syscall1 },
    .{ "syscall2", .syscall2 },
    .{ "syscall3", .syscall3 },
    .{ "syscall4", .syscall4 },
    .{ "syscall5", .syscall5 },
    .{ "syscall6", .syscall6 },
    .{ "=", .eq },
    .{ ">", .gt },
    .{ "<", .lt },
    .{ ">=", .ge },
    .{ "<=", .le },
    .{ "!=", .ne },
    .{ "if", .{ .@"if" = null } },
    .{ "else", .{ .@"else" = null } },
    .{ "while", .@"while" },
    .{ "do", .{ .do = null } },
    .{ "end", .{ .end = null } },
    .{ "macro", .macro },
    .{ "dup", .dup },
    .{ "2dup", .dup2 },
    .{ "swap", .swap },
    .{ "drop", .drop },
    .{ "over", .over },
});

fn parseTokenAsOp(token: *Token) ParseError!Op {
    return switch (token.value) {
        .int => |i| .{
            .loc = token.loc,
            .code = .{ .push_int = i },
        },
        .word => |w| .{
            .loc = token.loc,
            .code = builtin_words.get(w) orelse {
                std.debug.print("{}: unknown word {s}\n", .{ token.loc, w });
                return error.Parse;
            },
        },
        .str => |*s| {
            var temp: []const u8 = "";
            std.mem.swap([]const u8, s, &temp);
            return .{
                .loc = token.loc,
                .code = .{ .push_str = temp },
            };
        },
    };
}

fn lexWord(gpa: std.mem.Allocator, word: []const u8) !Token.Value {
    return if (std.fmt.parseInt(u63, word, 10)) |int|
        .{ .int = int }
    else |_|
        .{ .word = try gpa.dupe(u8, word) };
}

fn lexLine(
    gpa: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    file_path: []const u8,
    row: usize,
    line: []const u8,
) !void {
    var it = std.mem.tokenize(u8, line, &std.ascii.whitespace);
    while (it.next()) |word| {
        const col = @ptrToInt(word.ptr) - @ptrToInt(line.ptr);
        if (word[0] == '"') {
            const col_end = std.mem.indexOfScalarPos(u8, line, col + 1, '"') orelse {
                std.debug.print("{}: ERROR: unclosed string literal\n", .{Op.Location{
                    .file_path = file_path,
                    .row = row + 1,
                    .col = col + 1,
                }});
                return error.Parse;
            };
            const raw_text = line[col + 1 .. col_end];
            var token_text = try std.ArrayList(u8).initCapacity(gpa, raw_text.len);
            defer token_text.deinit();

            var offset: usize = 0;
            while (offset < raw_text.len) {
                const next_esc = std.mem.indexOfScalarPos(u8, raw_text, offset, '\\') orelse {
                    try token_text.appendSlice(raw_text[offset..]);
                    break;
                };
                try token_text.appendSlice(raw_text[offset..next_esc]);
                offset = next_esc;
                switch (std.zig.string_literal.parseEscapeSequence(raw_text, &offset)) {
                    .success => |cp| {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch unreachable;
                        try token_text.appendSlice(utf8_buf[0..len]);
                    },
                    .failure => |e| std.debug.panic("error: {any}\n", .{e}),
                }
            }

            try tokens.append(.{
                .loc = .{
                    .file_path = file_path,
                    .row = row + 1,
                    .col = col + 1,
                },
                .value = .{ .str = try token_text.toOwnedSlice() },
            });
            it = std.mem.tokenize(u8, line[col_end + 1 ..], &std.ascii.whitespace);
        } else try tokens.append(.{
            .loc = .{
                .file_path = file_path,
                .row = row + 1,
                .col = col + 1,
            },
            .value = try lexWord(gpa, word),
        });
    }
}

fn readLine(in: std.fs.File.Reader, buf: *std.ArrayList(u8)) !?[]const u8 {
    in.readUntilDelimiterArrayList(buf, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
        error.EndOfStream => if (buf.items.len == 0) return null,
        else => return e,
    };
    return buf.items;
}

fn parse(gpa: std.mem.Allocator, in: std.fs.File.Reader, file_path: []const u8) !std.ArrayList(Token) {
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();
    var tokens = std.ArrayList(Token).init(gpa);
    errdefer {
        for (tokens.items) |tok| switch (tok.value) {
            .str, .word => |s| gpa.free(s),
            else => {},
        };
        tokens.deinit();
    }
    var row: usize = 0;
    while (try readLine(in, &line_buf)) |line| : (row += 1) {
        const before_comment = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        try lexLine(gpa, &tokens, file_path, row, before_comment);
    }
    return tokens;
}

const Macro = struct {
    loc: Op.Location,
    gpa: std.mem.Allocator,
    tokens: std.ArrayList(Token),

    pub fn init(loc: Op.Location, gpa: std.mem.Allocator) @This() {
        return .{
            .loc = loc,
            .gpa = gpa,
            .tokens = std.ArrayList(Token).init(gpa),
        };
    }
};

const SemaError = error{Sema} || std.mem.Allocator.Error;

fn compile(
    // persistent
    gpa: std.mem.Allocator,
    // ephemeral
    arena: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
) SemaError!Program {
    var stack = std.ArrayList(usize).init(arena);
    defer stack.deinit();
    std.mem.reverse(Token, tokens.items);
    var macros = std.StringArrayHashMap(Macro).init(arena);

    var program = std.ArrayList(Op).init(gpa);
    errdefer {
        for (program.items) |op| switch (op.code) {
            .push_str => |s| gpa.free(s),
            else => {},
        };
        program.deinit();
    }

    var ip: usize = 0;
    while (tokens.popOrNull()) |token| {
        const op = switch (token.value) {
            .word => |word| if (builtin_words.get(word)) |builtin|
                Op.init(token.loc, builtin)
            else if (macros.get(word)) |macro| {
                const start = tokens.items.len;
                try tokens.ensureTotalCapacity(start + macro.tokens.items.len);
                for (macro.tokens.items) |src| {
                    tokens.appendAssumeCapacity(src);
                }
                std.mem.reverse(Token, tokens.items[start..]);
                continue;
            } else {
                std.debug.print("{}: unknown word '{s}'\n", .{ token.loc, word });
                return error.Sema;
            },
            .int => |value| Op{ .loc = token.loc, .code = .{ .push_int = value } },
            .str => |value| blk: {
                break :blk Op{
                    .loc = token.loc,
                    .code = .{ .push_str = try gpa.dupe(u8, value) },
                };
            },
        };

        switch (op.code) {
            .@"if", .@"while" => {
                try program.append(op);
                try stack.append(ip);
            },
            .@"else" => {
                try program.append(op);
                const if_ip = stack.pop();
                switch (program.items[if_ip].code) {
                    .@"if" => |*targ| {
                        targ.* = ip + 1;
                    },
                    else => {
                        std.debug.print("{}: ERROR: `else` can only be used in `if`-blocks\n", .{op.loc});
                        return error.Sema;
                    },
                }
                try stack.append(ip);
            },
            .do => {
                try program.append(op);
                const while_ip = stack.pop();
                program.items[ip].code.do = while_ip;
                try stack.append(ip);
            },
            .end => {
                try program.append(op);
                const block_ip = stack.pop();
                switch (program.items[block_ip].code) {
                    .@"if", .@"else" => |*targ| {
                        targ.* = ip;
                        program.items[ip].code.end = ip + 1;
                    },
                    .do => |*targ| {
                        program.items[ip].code.end = targ.*;
                        targ.* = ip + 1;
                    },
                    else => {
                        std.debug.print("{}: ERROR: `end` can only close `if`-blocks\n", .{op.loc});
                        return error.Sema;
                    },
                }
            },
            .macro => {
                const name_tok = tokens.popOrNull() orelse {
                    std.debug.print("{}: ERROR: expected macro name but found end of input\n", .{op.loc});
                    return error.Sema;
                };
                const name = switch (name_tok.value) {
                    .word => |w| w,
                    else => {
                        std.debug.print(
                            "{}: ERROR: expected macro name to be {s} but found {s}\n",
                            .{
                                name_tok.loc,
                                Token.Value.tagReadableName(.word),
                                name_tok.value.humanReadableName(),
                            },
                        );
                        return error.Sema;
                    },
                };
                if (builtin_words.get(name) != null) {
                    std.debug.print("{}: ERROR: redefinition of builtin word '{s}'\n", .{ name_tok.loc, name });
                    return error.Sema;
                }
                if (try macros.fetchPut(name, Macro.init(op.loc, arena))) |old| {
                    std.debug.print(
                        "{}: ERROR: redefinition of existing macro '{s}'\n",
                        .{ name_tok.loc, old.key },
                    );
                    return error.Sema;
                }
                const macro = macros.getPtr(name).?;

                var last_token: ?Token = null;
                var was_end = false;
                while (tokens.popOrNull()) |macro_tok| {
                    last_token = macro_tok;
                    switch (macro_tok.value) {
                        .word => |w| if (std.mem.eql(u8, w, "end")) {
                            was_end = true;
                            break;
                        },
                        else => {},
                    }
                    try macro.tokens.append(macro_tok);
                }
                if (!was_end) {
                    std.debug.print("{}: ERROR: expected 'end' at end of macro definition, got ", .{token.loc});
                    if (last_token) |t| {
                        switch (t.value) {
                            .word, .str => |text| std.debug.print("'{s}'\n", .{text}),
                            .int => |i| std.debug.print("'{d}'\n", .{i}),
                        }
                    } else {
                        std.debug.print("end of input\n", .{});
                    }
                    return error.Sema;
                }
            },
            .push_int,
            .push_str,
            .plus,
            .minus,
            .mod,
            .eq,
            .gt,
            .lt,
            .ge,
            .le,
            .ne,
            .shr,
            .shl,
            .bor,
            .band,
            .print,
            .mem,
            .load,
            .store,
            .syscall0,
            .syscall1,
            .syscall2,
            .syscall3,
            .syscall4,
            .syscall5,
            .syscall6,
            .dup,
            .dup2,
            .swap,
            .drop,
            .over,
            => {
                try program.append(op);
            },
        }

        ip += 1;
    }

    if (stack.items.len > 0) {
        std.debug.print("{}: ERROR: unclosed block\n", .{program.items[stack.pop()].loc});
        return error.Sema;
    }
    return Program.init(try program.toOwnedSlice());
}

pub const Error = SemaError ||
    ParseError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    error{ StreamTooLong, EndOfStream };

pub fn loadProgramFromFile(gpa: std.mem.Allocator, file_path: []const u8) Error!Program {
    const f = std.fs.cwd().openFile(file_path, .{}) catch |e| {
        std.debug.print("[ERROR] Failed to open '{s}'!\n", .{file_path});
        return e;
    };
    defer f.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tokens = try parse(arena.allocator(), f.reader(), file_path);
    return try compile(gpa, arena.allocator(), &tokens);
}
