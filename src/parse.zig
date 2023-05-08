const std = @import("std");
const Op = @import("ops.zig").Op;

const ParseError = error{Parse};

fn streq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseWordAsOp(word: []const u8) ParseError!Op {
    return if (streq(word, "+"))
        .plus
    else if (streq(word, "-"))
        .minus
    else if (streq(word, "."))
        .dump
    else blk: {
        const value = std.fmt.parseInt(u63, word, 10) catch {
            std.debug.print("ERROR: unknown word {s}\n", .{word});
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

fn parse(gpa: std.mem.Allocator, in: std.fs.File.Reader) ![]Op {
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();
    var program = std.ArrayList(Op).init(gpa);
    defer program.deinit();
    while (try readLine(in, &line_buf)) |line| {
        var it = std.mem.tokenize(u8, line, &std.ascii.whitespace);
        while (it.next()) |word| {
            try program.append(try parseWordAsOp(word));
        }
    }
    return try program.toOwnedSlice();
}

pub fn loadProgramFromFile(gpa: std.mem.Allocator, file_path: []const u8) ![]Op {
    const f = try std.fs.cwd().openFile(file_path, .{});
    defer f.close();

    return try parse(gpa, f.reader());
}
