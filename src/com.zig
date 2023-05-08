const std = @import("std");
const Op = @import("Op.zig");

const dump_asm = @embedFile("print.asm");

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
        try op.code.display(out);
        try out.writeAll(" --\n");
        switch (op.code) {
            .push => |x| {
                try emitf(&out, "mov rax, {d}", .{x});
                try emit(&out, "push rax");
            },
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
            .mod => {
                try emit(&out, "xor rdx, rdx");
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "div rbx");
                try emit(&out, "push rdx");
            },
            .eq => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "sete al");
                try emit(&out, "movzx rax, al");
                try emit(&out, "push rax");
            },
            .gt => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "movzx rax, al");
                try emit(&out, "setg al");
                try emit(&out, "push rax");
            },
            .lt => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "movzx rax, al");
                try emit(&out, "setl al");
                try emit(&out, "push rax");
            },
            .ge => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "movzx rax, al");
                try emit(&out, "setge al");
                try emit(&out, "push rax");
            },
            .le => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "movzx rax, al");
                try emit(&out, "setle al");
                try emit(&out, "push rax");
            },
            .ne => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "cmp rax, rbx");
                try emit(&out, "movzx rax, al");
                try emit(&out, "setne al");
                try emit(&out, "push rax");
            },
            .shr => {
                try emit(&out, "pop rcx");
                try emit(&out, "pop rbx");
                try emit(&out, "shr rbx, cl");
                try emit(&out, "push rbx");
            },
            .shl => {
                try emit(&out, "pop rcx");
                try emit(&out, "pop rbx");
                try emit(&out, "shl rbx, cl");
                try emit(&out, "push rbx");
            },
            .bor => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "or rax, rbx");
                try emit(&out, "push rax");
            },
            .band => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "and rax, rbx");
                try emit(&out, "push rax");
            },
            .print => {
                try emit(&out, "pop rdi");
                try emit(&out, "call print");
            },
            .mem => {
                try emit(&out, "push mem");
            },
            .load => {
                try emit(&out, "pop rax");
                try emit(&out, "xor rbx, rbx");
                try emit(&out, "mov bl, [rax]");
                try emit(&out, "push rbx");
            },
            .store => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "mov [rax], bl");
            },
            .syscall0 => {
                try emit(&out, "pop rax");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .syscall1 => {
                try emit(&out, "pop rax");
                try emit(&out, "pop rdi");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .syscall2 => {
                try emit(&out, "pop rax");
                try emit(&out, "pop rdi");
                try emit(&out, "pop rsi");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .syscall3 => {
                try emit(&out, "pop rax");
                try emit(&out, "pop rdi");
                try emit(&out, "pop rsi");
                try emit(&out, "pop rdx");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .syscall4 => {
                try emit(&out, "pop rax");
                try emit(&out, "pop rdi");
                try emit(&out, "pop rsi");
                try emit(&out, "pop rdx");
                try emit(&out, "pop r10");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .syscall5 => {
                try emit(&out, "pop rax");
                try emit(&out, "pop rdi");
                try emit(&out, "pop rsi");
                try emit(&out, "pop rdx");
                try emit(&out, "pop r10");
                try emit(&out, "pop r8");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .syscall6 => {
                try emit(&out, "pop rax");
                try emit(&out, "pop rdi");
                try emit(&out, "pop rsi");
                try emit(&out, "pop rdx");
                try emit(&out, "pop r10");
                try emit(&out, "pop r8");
                try emit(&out, "pop r9");
                try emit(&out, "syscall");
                try emit(&out, "push rax");
            },
            .@"if", .do => |maybe_targ| {
                const targ = maybe_targ.?;
                try emit(&out, "pop rax");
                try emit(&out, "test rax, rax");
                try emitf(&out, "jz " ++ porth_addr_prefix ++ "{d}", .{targ});
            },
            .@"while" => {},
            .@"else" => |maybe_targ| {
                const targ = maybe_targ.?;
                try emitf(&out, "jmp " ++ porth_addr_prefix ++ "{d}", .{targ});
            },
            .end => |maybe_targ| {
                const targ = maybe_targ.?;
                if (targ != ip + 1)
                    try emitf(&out, "jmp " ++ porth_addr_prefix ++ "{d}", .{targ});
            },
            .dup => {
                try emit(&out, "pop rax");
                try emit(&out, "push rax");
                try emit(&out, "push rax");
            },
            .dup2 => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "push rax");
                try emit(&out, "push rbx");
                try emit(&out, "push rax");
                try emit(&out, "push rbx");
            },
            .swap => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "push rbx");
                try emit(&out, "push rax");
            },
            .drop => {
                try emit(&out, "pop rax");
            },
            .over => {
                try emit(&out, "pop rbx");
                try emit(&out, "pop rax");
                try emit(&out, "push rax");
                try emit(&out, "push rbx");
                try emit(&out, "push rax");
            },
        }
    }
    try out.print(porth_addr_prefix ++ "{d}:\n", .{program.len});
    const SYS_WRITE = "60";
    try emit(&out, "mov rax, " ++ SYS_WRITE);
    try emit(&out, "mov rdi, 0");
    try emit(&out, "syscall");
    try out.writeAll("segment .bss\n");
    try out.print("mem: resb {d}\n", .{@import("opts").mem_capacity});
}
