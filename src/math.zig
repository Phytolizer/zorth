pub fn add(comptime T: type, x: T, y: T) T {
    return x +% y;
}

pub fn sub(comptime T: type, x: T, y: T) T {
    return x -% y;
}
