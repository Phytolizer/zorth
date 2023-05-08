const std = @import("std");
const Op = @import("Op.zig");

const ParseError = error{Parse};

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Token = struct {
    loc: Op.Location,
    word: []const u8,
};

const word_map = std.ComptimeStringMap(Op.Code, .{
    .{ "+", .plus },
    .{ "-", .minus },
    .{ "dump", .dump },
    .{ "mem", .mem },
    .{ ",", .load },
    .{ ".", .store },
    .{ "syscall1", .syscall1 },
    .{ "syscall2", .syscall2 },
    .{ "syscall3", .syscall3 },
    .{ "syscall4", .syscall4 },
    .{ "syscall5", .syscall5 },
    .{ "syscall6", .syscall6 },
    .{ "=", .equal },
    .{ ">", .gt },
    .{ "<", .lt },
    .{ "if", .{ .@"if" = null } },
    .{ "else", .{ .@"else" = null } },
    .{ "while", .@"while" },
    .{ "do", .{ .do = null } },
    .{ "end", .{ .end = null } },
    .{ "dup", .dup },
    .{ "2dup", .dup2 },
    .{ "swap", .swap },
    .{ "drop", .drop },
});

fn parseTokenAsOp(token: Token) ParseError!Op {
    const code = word_map.get(token.word) orelse blk: {
        const value = std.fmt.parseInt(u63, token.word, 10) catch {
            std.debug.print("{}: unknown word {s}\n", .{ token.loc, token.word });
            return error.Parse;
        };
        break :blk Op.Code{ .push = value };
    };
    return Op.init(token.loc, code);
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
    var program = std.ArrayList(Op).init(gpa);
    defer program.deinit();
    var row: usize = 0;
    while (try readLine(in, &line_buf)) |line| : (row += 1) {
        const before_comment = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        var it = std.mem.tokenize(u8, before_comment, &std.ascii.whitespace);
        while (it.next()) |word| {
            const col = @ptrToInt(word.ptr) - @ptrToInt(line.ptr);
            try program.append(try parseTokenAsOp(.{
                .loc = .{
                    .file_path = file_path,
                    .row = row + 1,
                    .col = col + 1,
                },
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
            .push,
            .plus,
            .minus,
            .equal,
            .gt,
            .lt,
            .dump,
            .mem,
            .load,
            .store,
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

pub fn loadProgramFromFile(gpa: std.mem.Allocator, file_path: []const u8) Error![]Op {
    const f = std.fs.cwd().openFile(file_path, .{}) catch |e| {
        std.debug.print("ERROR: Failed to open '{s}'!\n", .{file_path});
        return e;
    };
    defer f.close();

    const program = try parse(gpa, f.reader(), file_path);
    errdefer gpa.free(program);
    try crossReferenceBlocks(gpa, program);
    return program;
}
