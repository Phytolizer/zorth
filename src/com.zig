const std = @import("std");
const Op = @import("ops.zig").Op;

const dump_asm = @embedFile("dump.asm");

fn emit(out: anytype, comptime text: []const u8) !void {
    try emitf(out, text, .{});
}

fn emitf(out: anytype, comptime fmt: []const u8, args: anytype) !void {
    try out.print("    " ++ fmt ++ "\n", args);
}

const porth_addr_prefix = ".porth_addr_";

pub fn compileProgram(
    program: []const Op,
    out_file_path: []const u8,
) !void {
    var outf = try std.fs.cwd().createFile(out_file_path, .{});
    defer outf.close();

    var out_buf = std.io.bufferedWriter(outf.writer());
    defer out_buf.flush() catch {};
    const out = out_buf.writer();

    try out.writeAll(dump_asm);
    try out.writeAll("global _start\n");
    try out.writeAll("_start:\n");
    for (program, 0..) |op, ip| {
        try out.print(porth_addr_prefix ++ "{d}:\n", .{ip});
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
            .equal => {
                try emit(&out, "mov rcx, 0");
                try emit(&out, "mov rdx, 1");
                try emit(&out, "pop rax");
                try emit(&out, "pop rbx");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "cmove rcx, rdx");
                try emit(&out, "push rcx");
            },
            .gt => {
                try emit(&out, "mov rcx, 0");
                try emit(&out, "mov rdx, 1");
                try emit(&out, "pop rax");
                try emit(&out, "pop rbx");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "cmovg rcx, rdx");
                try emit(&out, "push rcx");
            },
            .dump => {
                try emit(&out, "pop rdi");
                try emit(&out, "call dump");
            },
            .@"if" => |maybe_targ| {
                const targ = maybe_targ.?;
                try emit(&out, "pop rax");
                try emit(&out, "test rax, rax");
                try emitf(&out, "jz " ++ porth_addr_prefix ++ "{d}", .{targ});
            },
            .@"else" => |maybe_targ| {
                const targ = maybe_targ.?;
                try emitf(&out, "jmp " ++ porth_addr_prefix ++ "{d}", .{targ});
            },
            .end => {},
            .dup => {
                try emit(&out, "pop rax");
                try emit(&out, "push rax");
                try emit(&out, "push rax");
            },
        }
    }
    try out.print(porth_addr_prefix ++ "{d}:\n", .{program.len});
    const SYS_WRITE = "60";
    try emit(&out, "mov rax, " ++ SYS_WRITE);
    try emit(&out, "mov rdi, 0");
    try emit(&out, "syscall");
}
