pub fn indexOfNone(comptime T: type, slice: []const T, values: []const T) ?usize {
    return indexOfNonePos(T, slice, 0, values);
}

pub fn lastIndexOfNone(comptime T: type, slice: []const T, values: []const T) ?usize {
    var i: usize = slice.len;
    outer: while (i != 0) {
        i -= 1;
        for (values) |value| {
            if (slice[i] == value) continue :outer;
        }
        return i;
    }
    return null;
}

pub fn indexOfNonePos(comptime T: type, slice: []const T, start_index: usize, values: []const T) ?usize {
    var i: usize = start_index;
    outer: while (i < slice.len) : (i += 1) {
        for (values) |value| {
            if (slice[i] == value) continue :outer;
        }
        return i;
    }
    return null;
}
