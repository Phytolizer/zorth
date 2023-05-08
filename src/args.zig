pub fn shift(args: *[]const []const u8) ?[]const u8 {
    if (args.len == 0) return null;

    const result = args.*[0];
    args.* = args.*[1..];
    return result;
}
