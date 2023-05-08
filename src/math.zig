pub fn add(comptime T: type, x: T, y: T) T {
    return x +% y;
}

pub fn sub(comptime T: type, x: T, y: T) T {
    return x -% y;
}

pub fn eq(comptime T: type, x: T, y: T) T {
    return @boolToInt(x == y);
}

pub fn gt(comptime T: type, x: T, y: T) T {
    return @boolToInt(x > y);
}

pub fn lt(comptime T: type, x: T, y: T) T {
    return @boolToInt(x < y);
}

pub fn ge(comptime T: type, x: T, y: T) T {
    return @boolToInt(x >= y);
}

pub fn le(comptime T: type, x: T, y: T) T {
    return @boolToInt(x <= y);
}

pub fn ne(comptime T: type, x: T, y: T) T {
    return @boolToInt(x != y);
}

pub fn shr(comptime T: type, x: T, y: T) T {
    return x >> @truncate(u6, @intCast(usize, y));
}

pub fn shl(comptime T: type, x: T, y: T) T {
    return x << @truncate(u6, @intCast(usize, y));
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
