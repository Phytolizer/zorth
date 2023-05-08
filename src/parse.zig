const std = @import("std");
const Op = @import("ops.zig").Op;

const ParseError = error{Parse};

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Token = struct {
    file_path: []const u8,
    row: usize,
    col: usize,
    word: []const u8,
};

const word_map = std.ComptimeStringMap(Op, .{
    .{ "+", .plus },
    .{ "-", .minus },
    .{ ".", .dump },
    .{ "=", .equal },
    .{ ">", .gt },
    .{ "if", .{ .@"if" = null } },
    .{ "else", .{ .@"else" = null } },
    .{ "end", .end },
    .{ "dup", .dup },
});

fn parseTokenAsOp(token: Token) ParseError!Op {
    return word_map.get(token.word) orelse blk: {
        const value = std.fmt.parseInt(u63, token.word, 10) catch {
            std.debug.print(
                "{s}:{d}:{d}: unknown word {s}\n",
                .{ token.file_path, token.row, token.col, token.word },
            );
            return error.Parse;
        };
        break :blk .{ .push = value };
    };
}

fn readLine(in: std.fs.File.Reader, buf: *std.ArrayList(u8)) !?[]const u8 {
    in.readUntilDelimiterArrayList(buf, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return e,
    };
    return buf.items;
}

fn parse(gpa: std.mem.Allocator, in: std.fs.File.Reader, file_path: []const u8) ![]Op {
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();
    var program = std.ArrayList(Op).init(gpa);
    defer program.deinit();
    var row: usize = 0;
    while (try readLine(in, &line_buf)) |line| : (row += 1) {
        var it = std.mem.tokenize(u8, line, &std.ascii.whitespace);
        while (it.next()) |word| {
            const col = @ptrToInt(word.ptr) - @ptrToInt(line.ptr);
            try program.append(try parseTokenAsOp(.{
                .file_path = file_path,
                .row = row + 1,
                .col = col + 1,
                .word = word,
            }));
        }
    }
    return try program.toOwnedSlice();
}

const SemaError = error{Sema} || std.mem.Allocator.Error;

fn crossReferenceBlocks(gpa: std.mem.Allocator, program: []Op) SemaError!void {
    var stack = std.ArrayList(usize).init(gpa);
    defer stack.deinit();

    for (program, 0..) |*op, ip| {
        switch (op.*) {
            .@"if" => {
                try stack.append(ip);
            },
            .@"else" => {
                const if_ip = stack.pop();
                switch (program[if_ip]) {
                    .@"if" => |*targ| {
                        targ.* = ip + 1;
                    },
                    else => {
                        std.debug.print("`else` can only be used in `if`-blocks\n", .{});
                        return error.Sema;
                    },
                }
                try stack.append(ip);
            },
            .end => {
                const if_ip = stack.pop();
                switch (program[if_ip]) {
                    .@"if", .@"else" => |*targ| {
                        targ.* = ip;
                    },
                    else => {
                        std.debug.print("`end` can only close `if`-blocks\n", .{});
                        return error.Sema;
                    },
                }
            },
            .push,
            .plus,
            .minus,
            .equal,
            .gt,
            .dump,
            .dup,
            => {},
        }
    }
}

pub fn loadProgramFromFile(gpa: std.mem.Allocator, file_path: []const u8) ![]Op {
    const f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();

    const program = try parse(gpa, f.reader(), file_path);
    try crossReferenceBlocks(gpa, program);
    return program;
}
