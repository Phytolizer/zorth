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
    };
};

const word_map = std.ComptimeStringMap(Op.Code, .{
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
            .code = word_map.get(w) orelse {
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
            const col_end = std.mem.indexOfScalarPos(u8, line, col + 1, '"') orelse
                std.debug.panic("no close quote found", .{});
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

fn parse(gpa: std.mem.Allocator, in: std.fs.File.Reader, file_path: []const u8) ![]Op {
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();
    var tokens = std.ArrayList(Token).init(gpa);
    defer {
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
    var program = try std.ArrayList(Op).initCapacity(gpa, tokens.items.len);
    defer program.deinit();
    for (tokens.items) |*tok| {
        program.appendAssumeCapacity(try parseTokenAsOp(tok));
    }
    return try program.toOwnedSlice();
}

const SemaError = error{Sema} || std.mem.Allocator.Error;

fn crossReferenceBlocks(gpa: std.mem.Allocator, program: []Op) SemaError!void {
    var stack = std.ArrayList(usize).init(gpa);
    defer stack.deinit();

    for (program, 0..) |*op, ip| {
        switch (op.code) {
            .@"if", .@"while" => {
                try stack.append(ip);
            },
            .@"else" => {
                const if_ip = stack.pop();
                switch (program[if_ip].code) {
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
            .do => |*targ| {
                const while_ip = stack.pop();
                targ.* = while_ip;
                try stack.append(ip);
            },
            .end => |*end_targ| {
                const block_ip = stack.pop();
                switch (program[block_ip].code) {
                    .@"if", .@"else" => |*targ| {
                        targ.* = ip;
                        end_targ.* = ip + 1;
                    },
                    .do => |*targ| {
                        end_targ.* = targ.*;
                        targ.* = ip + 1;
                    },
                    else => {
                        std.debug.print("{}: ERROR: `end` can only close `if`-blocks\n", .{op.loc});
                        return error.Sema;
                    },
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
            => {},
        }
    }

    if (stack.items.len > 0) {
        std.debug.print("{}: ERROR: unclosed block\n", .{program[stack.pop()].loc});
        return error.Sema;
    }
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

    const program = Program.init(try parse(gpa, f.reader(), file_path));
    errdefer program.deinit(gpa);
    try crossReferenceBlocks(gpa, program.items);
    return program;
}
