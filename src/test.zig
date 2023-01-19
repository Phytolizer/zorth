const std = @import("std");
const zorth = @import("zorth");
const common = @import("common.zig");

var a: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    a = gpa.allocator();
    var iter_dir = try std.fs.cwd().openIterableDir("tests", .{});
    var w = try iter_dir.walk(a);
    defer w.deinit();
    while (try w.next()) |ent| {
        if (ent.kind == .File and std.mem.endsWith(u8, ent.basename, ".zorth")) {
            const real_path = try iter_dir.dir.realpathAlloc(a, ent.path);
            defer a.free(real_path);
            std.log.info("Testing {s}", .{real_path});
            var sim_output_arr = std.ArrayList(u8).init(a);
            defer sim_output_arr.deinit();
            var sim_output = sim_output_arr.writer();
            _ = try zorth.driver(a, &.{ "zorth", "sim", real_path }, sim_output, std.io.null_writer);
            var com_output_arr = std.ArrayList(u8).init(a);
            defer com_output_arr.deinit();
            var com_output = com_output_arr.writer();
            _ = try zorth.driver(a, &.{ "zorth", "com", "-r", real_path }, com_output, std.io.null_writer);
            if (!std.mem.eql(u8, sim_output_arr.items, com_output_arr.items)) {
                std.log.err("failed", .{});
                std.debug.print("sim output:\n{s}\n", .{sim_output_arr.items});
                std.debug.print("com output:\n{s}\n", .{com_output_arr.items});
                return error.TestFailed;
            }
        }
    }
}
