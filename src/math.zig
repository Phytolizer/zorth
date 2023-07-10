const std = @import("std");

pub fn add(comptime T: type, x: T, y: T) T {
    return x +% y;
}

pub fn sub(comptime T: type, x: T, y: T) T {
    return x -% y;
}

pub fn mul(comptime T: type, x: T, y: T) T {
    return x *% y;
}

pub fn div(comptime T: type, x: T, y: T) T {
    return std.math.divTrunc(T, x, y) catch |e| std.debug.panic(
        "dividing: {s}\n",
        .{@errorName(e)},
    );
}

pub fn eq(comptime T: type, x: T, y: T) T {
    return @intFromBool(x == y);
}

pub fn gt(comptime T: type, x: T, y: T) T {
    return @intFromBool(x > y);
}

pub fn lt(comptime T: type, x: T, y: T) T {
    return @intFromBool(x < y);
}

pub fn ge(comptime T: type, x: T, y: T) T {
    return @intFromBool(x >= y);
}

pub fn le(comptime T: type, x: T, y: T) T {
    return @intFromBool(x <= y);
}

pub fn ne(comptime T: type, x: T, y: T) T {
    return @intFromBool(x != y);
}

pub fn shr(comptime T: type, x: T, y: T) T {
    return x >> @as(u6, @truncate(@as(usize, @intCast(y))));
}

pub fn shl(comptime T: type, x: T, y: T) T {
    return x << @as(u6, @truncate(@as(usize, @intCast(y))));
}

pub fn bor(comptime T: type, x: T, y: T) T {
    return x | y;
}

pub fn band(comptime T: type, x: T, y: T) T {
    return x & y;
}

pub fn mod(comptime T: type, x: T, y: T) T {
    return @mod(x, y);
}
