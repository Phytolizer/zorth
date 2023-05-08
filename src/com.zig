const std = @import("std");
const Op = @import("ops.zig").Op;

const dump_asm = @embedFile("dump.asm");

fn emit(out: anytype, comptime text: []const u8) !void {
    try emitf(out, text, .{});
}

fn emitf(out: anytype, comptime fmt: []const u8, args: anytype) !void {
    try out.print("    " ++ fmt ++ "\n", args);
}

pub fn compileProgram(
    program: []const Op,
    out_file_path: []const u8,
) !void {
    var outf = try std.fs.cwd().createFile(out_file_path, .{});
    defer outf.close();

    const out = outf.writer();

    try out.writeAll(dump_asm);
    try out.writeAll("global _start\n");
    try out.writeAll("_start:\n");
    for (program) |op| {
        try out.writeAll("    ;; -- ");
        try Op.display(op, out);
        try out.writeAll(" --\n");
        switch (op) {
            .push => |x| try emitf(&out, "push {d}", .{x}),
            .plus => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "add rax, rbx");
                try emit(&out, "push rax");
            },
            .minus => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "sub rax, rbx");
                try emit(&out, "push rax");
            },
            .dump => {
                try emit(&out, "pop rdi");
                try emit(&out, "call dump");
            },
        }
    }
    const SYS_WRITE = "60";
    try emit(&out, "mov rax, " ++ SYS_WRITE);
    try emit(&out, "mov rdi, 0");
    try emit(&out, "syscall");
}
