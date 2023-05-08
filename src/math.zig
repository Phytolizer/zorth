pub fn add(comptime T: type, x: T, y: T) T {
    return x +% y;
}

pub fn sub(comptime T: type, x: T, y: T) T {
    return x -% y;
}

pub fn equal(comptime T: type, x: T, y: T) T {
    return @boolToInt(x == y);
}

pub fn gt(comptime T: type, x: T, y: T) T {
    return @boolToInt(x > y);
}
