const std = @import("std");
const Op = @import("Op.zig");
const Program = @import("Program.zig");
const Token = @import("Token.zig");
const Keyword = @import("keyword.zig").Keyword;
const Intrinsic = @import("intrinsic.zig").Intrinsic;

const ParseError = error{Parse};

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn lexWord(gpa: std.mem.Allocator, word: []const u8) !Token.Value {
    return if (std.fmt.parseInt(u64, word, 10)) |int|
        .{ .int = int }
    else |_| if (Keyword.names.get(word)) |kw|
        .{ .keyword = kw }
    else
        .{ .word = try gpa.dupe(u8, word) };
}

fn stringLitEnd(line: []const u8, start: usize, quote: u8) ?usize {
    var pos = start;
    while (std.mem.indexOfScalarPos(u8, line, pos, quote)) |new_pos| {
        pos = new_pos + 1;
        if (new_pos == 0 or line[new_pos - 1] != '\\') return new_pos;
    }
    return null;
}

fn parseEscapes(
    gpa: std.mem.Allocator,
    loc: Op.Location,
    raw_text: []const u8,
    stderr: anytype,
) ![]const u8 {
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
            .failure => |e| {
                const err_loc = Op.Location{
                    .file_path = loc.file_path,
                    .row = loc.row,
                    .col = loc.col + switch (e) {
                        inline else => |i| i,
                    },
                };
                try stderr.print("{}: ERROR: could not parse escape sequence\n", .{err_loc});
                return error.Parse;
            },
        }
    }
    return try token_text.toOwnedSlice();
}

fn getLine(text: []const u8, line_starts: []const usize, row: usize) []const u8 {
    return if (row + 1 < line_starts.len)
        text[line_starts[row] .. line_starts[row + 1] - 1]
    else
        text[line_starts[row]..];
}

fn lexLines(
    gpa: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    file_path: []const u8,
    text: []const u8,
    stderr: anytype,
) !void {
    var row: usize = 0;
    var string_lit = std.ArrayList(u8).init(gpa);
    var line_starts = std.ArrayList(usize).init(gpa);
    {
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |new_pos| {
            try line_starts.append(pos);
            pos = new_pos + 1;
        }
        if (pos < text.len)
            try line_starts.append(pos);
    }
    while (row < line_starts.items.len) : (row += 1) {
        var line = getLine(text, line_starts.items, row);
        var it = std.mem.tokenize(u8, line, &std.ascii.whitespace);
        while (it.next()) |word| {
            var col = @intFromPtr(word.ptr) - @intFromPtr(line.ptr);
            const loc = Op.Location{
                .file_path = file_path,
                .row = row + 1,
                .col = col + 1,
            };
            switch (word[0]) {
                '"' => {
                    var first = true;
                    var col_end = col;
                    while (row < line_starts.items.len) {
                        var start = col;
                        if (first) {
                            first = false;
                            start += 1;
                        } else {
                            line = getLine(text, line_starts.items, row);
                        }
                        col_end = stringLitEnd(line, start, '"') orelse {
                            try string_lit.appendSlice(line[start..]);
                            try string_lit.append('\n');
                            row += 1;
                            col = 0;
                            continue;
                        };
                        try string_lit.appendSlice(line[start..col_end]);
                        break;
                    }
                    if (row >= line_starts.items.len) {
                        try stderr.print("{}: ERROR: unclosed string literal\n", .{loc});
                        return error.Parse;
                    }
                    const token_text = try string_lit.toOwnedSlice();
                    try tokens.append(.{
                        .loc = loc,
                        .value = .{ .str = try parseEscapes(gpa, loc, token_text, stderr) },
                    });
                    it = std.mem.tokenize(u8, line[col_end + 1 ..], &std.ascii.whitespace);
                },
                '\'' => {
                    const col_end = stringLitEnd(line, col + 1, '\'') orelse {
                        try stderr.print("{}: ERROR: unclosed character literal\n", .{loc});
                        return error.Parse;
                    };
                    const raw_text = line[col + 1 .. col_end];
                    const utf8 = try parseEscapes(gpa, loc, raw_text, stderr);
                    if (utf8.len == 0) {
                        try stderr.print(
                            "{}: ERROR: invalid character literal '{s}': no data\n",
                            .{ loc, raw_text },
                        );
                        return error.Parse;
                    }
                    const bs_len = std.unicode.utf8ByteSequenceLength(utf8[0]) catch {
                        try stderr.print(
                            "{}: ERROR: invalid character literal '{s}': not valid UTF-8\n",
                            .{ loc, raw_text },
                        );
                        return error.Parse;
                    };
                    if (utf8.len != bs_len) {
                        try stderr.print(
                            "{}: ERROR: invalid character literal '{s}': too {s}\n",
                            .{ loc, raw_text, if (utf8.len > bs_len) "long" else "short" },
                        );
                        return error.Parse;
                    }
                    const ch = std.unicode.utf8Decode(utf8) catch |e| {
                        try stderr.print(
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
                else => {
                    if (std.mem.startsWith(u8, word, "//")) {
                        break;
                    } else try tokens.append(.{
                        .loc = loc,
                        .value = try lexWord(gpa, word),
                    });
                },
            }
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

fn parse(
    gpa: std.mem.Allocator,
    in: std.fs.File.Reader,
    file_path: []const u8,
    expanded_depth: usize,
    stderr: anytype,
) !std.ArrayList(Token) {
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();
    var tokens = std.ArrayList(Token).init(gpa);
    const contents = try in.readAllAlloc(gpa, std.math.maxInt(usize));
    try lexLines(gpa, &tokens, file_path, contents, stderr);
    for (tokens.items) |*tok|
        tok.expanded_depth = expanded_depth;
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

fn expandMacro(
    gpa: std.mem.Allocator,
    macro: Macro,
    expanded_depth: usize,
) ![]Token {
    const result = try gpa.dupe(Token, macro.tokens.items);
    for (result) |*token|
        token.expanded_depth = expanded_depth;
    return result;
}

fn compile(
    // persistent
    gpa: std.mem.Allocator,
    // ephemeral
    arena: std.mem.Allocator,
    tokens: *std.ArrayList(Token),
    include_paths: []const []const u8,
    expansion_limit: usize,
    stderr: anytype,
) Error!Program {
    var stack = std.ArrayList(usize).init(arena);
    defer stack.deinit();
    std.mem.reverse(Token, tokens.items);
    var macros = std.StringArrayHashMap(Macro).init(arena);

    var program = std.ArrayList(Op).init(gpa);
    errdefer {
        for (program.items) |op| {
            gpa.free(op.loc.file_path);
            switch (op.code) {
                .push_str => |s| gpa.free(s),
                else => {},
            }
        }
        program.deinit();
    }

    var ip: usize = 0;
    while (tokens.popOrNull()) |token| {
        switch (token.value) {
            .word => |word| {
                if (Intrinsic.names.get(word)) |intrinsic| {
                    try program.append(Op.init(token.loc, .{ .intrinsic = intrinsic }));
                    ip += 1;
                } else if (macros.get(word)) |macro| {
                    if (token.expanded_depth >= expansion_limit) {
                        try stderr.print(
                            "{}: ERROR: macro exceeded expansion limit ({d})\n",
                            .{ token.loc, token.expanded_depth },
                        );
                        return error.Sema;
                    }
                    const macro_tokens = try expandMacro(arena, macro, token.expanded_depth + 1);
                    std.mem.reverse(Token, macro_tokens);
                    try tokens.appendSlice(macro_tokens);
                } else {
                    try stderr.print("{}: ERROR: unknown word '{s}'\n", .{ token.loc, word });
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
                            try stderr.print(
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
                            try stderr.print(
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
                        try stderr.print(
                            "{}: ERROR: expected macro name but found end of input\n",
                            .{token.loc},
                        );
                        return error.Sema;
                    };
                    const name = switch (name_tok.value) {
                        .word => |w| w,
                        else => {
                            try stderr.print(
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
                    if (Intrinsic.names.get(name) != null) {
                        try stderr.print(
                            "{}: ERROR: redefinition of intrinsic '{s}'. Please choose a different macro name.\n",
                            .{ name_tok.loc, name },
                        );
                        return error.Sema;
                    }
                    if (try macros.fetchPut(name, Macro.init(token.loc, arena))) |old| {
                        try stderr.print(
                            "{}: ERROR: redefinition of existing macro '{s}'\n",
                            .{ name_tok.loc, old.key },
                        );
                        return error.Sema;
                    }
                    const macro = macros.getPtr(name).?;

                    var last_token: ?Token = null;
                    var was_end = false;
                    var nesting_depth: usize = 0;
                    while (tokens.popOrNull()) |macro_tok| {
                        last_token = macro_tok;
                        switch (macro_tok.value) {
                            .keyword => |k| if (k == .end and nesting_depth == 0) {
                                was_end = true;
                                break;
                            },
                            else => {},
                        }
                        try macro.tokens.append(macro_tok);
                        switch (macro_tok.value) {
                            .keyword => |k| switch (k) {
                                .@"if", .@"while", .macro => nesting_depth += 1,
                                .end => nesting_depth -= 1,
                                else => {},
                            },
                            else => {},
                        }
                    }
                    if (!was_end) {
                        try stderr.print(
                            "{}: ERROR: expected 'end' at end of macro definition, got ",
                            .{token.loc},
                        );
                        if (last_token) |t| {
                            try stderr.print("{}\n", .{t.value});
                        } else {
                            try stderr.print("end of input\n", .{});
                        }
                        return error.Sema;
                    }
                },
                .include => {
                    const path_tok = tokens.popOrNull() orelse {
                        try stderr.print(
                            "{}: ERROR: expected include path but found end of input\n",
                            .{token.loc},
                        );
                        return error.Sema;
                    };
                    const path = switch (path_tok.value) {
                        .str => |s| s,
                        else => {
                            try stderr.print(
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
                    if (token.expanded_depth >= expansion_limit) {
                        try stderr.print(
                            "{}: ERROR: include exceeded expansion limit ({d})\n",
                            .{ token.loc, token.expanded_depth },
                        );
                        return error.Sema;
                    }
                    var include_file = doInclude: {
                        if (std.fs.path.isAbsolute(path)) {
                            if (std.fs.openFileAbsolute(path, .{})) |f|
                                break :doInclude f
                            else |_| {}
                        } else for (include_paths) |include_path| {
                            const full_path = try std.fs.path.join(arena, &.{ include_path, path });
                            if (std.fs.cwd().openFile(full_path, .{})) |f| {
                                const stat = try f.stat();
                                if (stat.kind != .file) continue;
                                break :doInclude f;
                            } else |_| continue;
                        }
                        try stderr.print(
                            "{}: ERROR: file '{s}' could not be opened\n",
                            .{ path_tok.loc, path },
                        );
                        return error.Sema;
                    };
                    defer include_file.close();
                    const included_tokens = try parse(
                        arena,
                        include_file.reader(),
                        path,
                        token.expanded_depth + 1,
                        stderr,
                    );
                    std.mem.reverse(Token, included_tokens.items);
                    try tokens.appendSlice(included_tokens.items);
                },
            },
        }
    }

    if (stack.items.len > 0) {
        try stderr.print("{}: ERROR: unclosed block\n", .{program.items[stack.pop()].loc});
        return error.Sema;
    }

    // copy program file paths to avoid UAF
    for (program.items) |*tok| {
        tok.loc.file_path = try gpa.dupe(u8, tok.loc.file_path);
    }

    return Program.init(try program.toOwnedSlice());
}

pub const Error = SemaError ||
    ParseError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    error{ StreamTooLong, EndOfStream };

pub fn loadProgramFromFile(
    gpa: std.mem.Allocator,
    file_path: []const u8,
    include_paths: []const []const u8,
    expansion_limit: usize,
    stderr: anytype,
) Error!Program {
    const f = std.fs.cwd().openFile(file_path, .{}) catch |e| {
        try stderr.print("[ERROR] Failed to open '{s}'!\n", .{file_path});
        return e;
    };
    defer f.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var tokens = try parse(arena.allocator(), f.reader(), file_path, 0, stderr);
    return try compile(
        gpa,
        arena.allocator(),
        &tokens,
        include_paths,
        expansion_limit,
        stderr,
    );
}
