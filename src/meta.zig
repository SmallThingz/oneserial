const std = @import("std");

pub const MathError = error{LengthOverflow};

pub fn addChecked(lhs: usize, rhs: usize) MathError!usize {
    return std.math.add(usize, lhs, rhs) catch error.LengthOverflow;
}

pub fn alignForwardChecked(pos: usize, comptime alignment: usize) MathError!usize {
    if (alignment <= 1) return pos;
    const rem = pos % alignment;
    if (rem == 0) return pos;
    return addChecked(pos, alignment - rem);
}

pub fn usizeFromAnyInt(v: anytype) MathError!usize {
    return std.math.cast(usize, v) orelse error.LengthOverflow;
}

pub fn castUsize(comptime T: type, value: usize) MathError!T {
    return std.math.cast(T, value) orelse error.LengthOverflow;
}

test {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 8), try alignForwardChecked(5, 4));
    try testing.expectEqual(@as(usize, 8), try alignForwardChecked(8, 4));
    try testing.expectEqual(@as(usize, 16), try addChecked(7, 9));
}
