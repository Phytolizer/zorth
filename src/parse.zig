const std = @import("std");
const Op = @import("Op.zig");
const Program = @import("Program.zig");
const Token = @import("Token.zig");
const Keyword = @import("keyword.zig").Keyword;

const ParseError = error{Parse};

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const builtin_words = std.ComptimeStringMap(Op.Code, .{
    .{ "+", .plus },
    .{ "-", .minus },
    .{ "*", .mul },
    .{ "divmod", .divmod },
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
    .{ "dup", .dup },
    .{ "swap", .swap },
    .{ "drop", .drop },
    .{ "over", .over },
});

fn lexWord(gpa: std.mem.Allocator, word: []const u8) !Token.Value {
    return if (std.fmt.parseInt(u63, word, 10)) |int|
        .{ .int = int }
    else |_| if (Keyword.names.get(word)) |kw|
        .{ .keyword = kw }
    else
        .{ .word = try gpa.dupe(u8, word) };
}

fn parseEscapes(gpa: std.mem.Allocator, raw_text: []const u8) ![]const u8 {
    var token_text = try std.ArrayList(u8).initCapacity(gpa, raw_text.len);

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
    return try token_text.toOwnedSlice();
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
        const loc = Op.Location{
            .file_path = file_path,
            .row = row + 1,
            .col = col + 1,
        };
        switch (word[0]) {
            '"' => {
                const col_end = std.mem.indexOfScalarPos(u8, line, col + 1, '"') orelse {
                    std.debug.print("{}: ERROR: unclosed string literal\n", .{loc});
                    return error.Parse;
                };
                try tokens.append(.{
                    .loc = loc,
                    .value = .{ .str = try parseEscapes(gpa, line[col + 1 .. col_end]) },
                });
                it = std.mem.tokenize(u8, line[col_end + 1 ..], &std.ascii.whitespace);
            },
            '\'' => {
                const col_end = std.mem.indexOfScalarPos(u8, line, col + 1, '\'') orelse {
                    std.debug.print("{}: ERROR: unclosed character literal\n", .{loc});
                    return error.Parse;
                };
                const raw_text = line[col + 1 .. col_end];
                const utf8 = try parseEscapes(gpa, raw_text);
                if (utf8.len == 0) {
                    std.debug.print(
                        "{}: ERROR: invalid character literal '{s}': no data\n",
                        .{ loc, raw_text },
                    );
                    return error.Parse;
                }
                const bs_len = std.unicode.utf8ByteSequenceLength(utf8[0]) catch {
                    std.debug.print(
                        "{}: ERROR: invalid character literal '{s}': not valid UTF-8\n",
                        .{ loc, raw_text },
                    );
                    return error.Parse;
                };
                if (utf8.len != bs_len) {
                    std.debug.print(
                        "{}: ERROR: invalid character literal '{s}': too {s}\n",
                        .{ loc, raw_text, if (utf8.len > bs_len) "long" else "short" },
                    );
                    return error.Parse;
                }
                const ch = std.unicode.utf8Decode(utf8) catch |e| {
                    std.debug.print(
                        "{}: ERROR: invalid character literal: {s}\n",
                        .{ loc, @errorName(e) },
                    );
                    return error.Parse;
                };
                try tokens.append(.{
                    .loc = loc,
                    .value = .{ .character = ch },
                });
                it = std.mem.tokenize(u8, line[col_end + 1 ..], &std.ascii.whitespace);
            },
            else => try tokens.append(.{
                .loc = loc,
                .value = try lexWord(gpa, word),
            }),
        }
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
    include_paths: []const []const u8,
) Error!Program {
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
        switch (token.value) {
            .word => |word| {
                if (builtin_words.get(word)) |builtin| {
                    try program.append(Op.init(token.loc, builtin));
                    ip += 1;
                } else if (macros.get(word)) |macro| {
                    const start = tokens.items.len;
                    try tokens.ensureTotalCapacity(start + macro.tokens.items.len);
                    for (macro.tokens.items) |src| {
                        tokens.appendAssumeCapacity(src);
                    }
                    std.mem.reverse(Token, tokens.items[start..]);
                } else {
                    std.debug.print("{}: unknown word '{s}'\n", .{ token.loc, word });
                    return error.Sema;
                }
            },
            .int => |value| {
                try program.append(Op{ .loc = token.loc, .code = .{ .push_int = value } });
                ip += 1;
            },
            .str => |value| {
                try program.append(Op{
                    .loc = token.loc,
                    .code = .{ .push_str = try gpa.dupe(u8, value) },
                });
                ip += 1;
            },
            .character => |ch| {
                try program.append(Op{ .loc = token.loc, .code = .{ .push_int = ch } });
                ip += 1;
            },
            .keyword => |kw| switch (kw) {
                .@"if" => {
                    try program.append(Op{ .loc = token.loc, .code = .{ .@"if" = null } });
                    try stack.append(ip);
                    ip += 1;
                },
                .@"else" => {
                    try program.append(Op{ .loc = token.loc, .code = .{ .@"else" = null } });
                    const if_ip = stack.pop();
                    switch (program.items[if_ip].code) {
                        .@"if" => |*targ| {
                            targ.* = ip + 1;
                        },
                        else => {
                            std.debug.print(
                                "{}: ERROR: `else` can only be used in `if`-blocks\n",
                                .{token.loc},
                            );
                            return error.Sema;
                        },
                    }
                    try stack.append(ip);
                    ip += 1;
                },
                .@"while" => {
                    try program.append(Op{ .loc = token.loc, .code = .@"while" });
                    try stack.append(ip);
                    ip += 1;
                },
                .do => {
                    try program.append(Op{ .loc = token.loc, .code = .{ .do = null } });
                    const while_ip = stack.pop();
                    program.items[ip].code.do = while_ip;
                    try stack.append(ip);
                    ip += 1;
                },
                .end => {
                    try program.append(Op{ .loc = token.loc, .code = .{ .end = null } });
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
                            std.debug.print(
                                "{}: ERROR: `end` can only close `if`-blocks\n",
                                .{token.loc},
                            );
                            return error.Sema;
                        },
                    }
                    ip += 1;
                },
                .macro => {
                    const name_tok = tokens.popOrNull() orelse {
                        std.debug.print(
                            "{}: ERROR: expected macro name but found end of input\n",
                            .{token.loc},
                        );
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
                    if (try macros.fetchPut(name, Macro.init(token.loc, arena))) |old| {
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
                            .keyword => |k| if (k == .end) {
                                was_end = true;
                                break;
                            },
                            else => {},
                        }
                        try macro.tokens.append(macro_tok);
                    }
                    if (!was_end) {
                        std.debug.print(
                            "{}: ERROR: expected 'end' at end of macro definition, got ",
                            .{token.loc},
                        );
                        if (last_token) |t| {
                            std.debug.print("{}\n", .{t.value});
                        } else {
                            std.debug.print("end of input\n", .{});
                        }
                        return error.Sema;
                    }
                },
                .include => {
                    const path_tok = tokens.popOrNull() orelse {
                        std.debug.print(
                            "{}: ERROR: expected include path but found end of input\n",
                            .{token.loc},
                        );
                        return error.Sema;
                    };
                    const path = switch (path_tok.value) {
                        .str => |s| s,
                        else => {
                            std.debug.print(
                                "{}: ERROR: expected include path to be {s} but found {s}\n",
                                .{
                                    path_tok.loc,
                                    Token.Value.tagReadableName(.word),
                                    path_tok.value.humanReadableName(),
                                },
                            );
                            return error.Sema;
                        },
                    };
                    var include_file = doInclude: {
                        if (std.fs.path.isAbsolute(path)) {
                            if (std.fs.openFileAbsolute(path, .{})) |f|
                                break :doInclude f
                            else |_| {}
                        } else for (include_paths) |include_path| {
                            const full_path = try std.fs.path.join(arena, &.{ include_path, path });
                            if (std.fs.cwd().openFile(full_path, .{})) |f| {
                                const stat = try f.stat();
                                if (stat.kind != .File) continue;
                                break :doInclude f;
                            } else |_| continue;
                        }
                        std.debug.print(
                            "{}: ERROR: file '{s}' could not be opened\n",
                            .{ path_tok.loc, path },
                        );
                        return error.Sema;
                    };
                    defer include_file.close();
                    const included_tokens = try parse(arena, include_file.reader(), path);
                    std.mem.reverse(Token, included_tokens.items);
                    try tokens.appendSlice(included_tokens.items);
                },
            },
        }
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

pub fn loadProgramFromFile(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    include_paths: []const []const u8,
) Error!Program {
    const f = std.fs.cwd().openFile(file_path, .{}) catch |e| {
        std.debug.print("[ERROR] Failed to open '{s}'!\n", .{file_path});
        return e;
    };
    defer f.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tokens = try parse(arena.allocator(), f.reader(), file_path);
    return try compile(gpa, arena.allocator(), &tokens, include_paths);
}
