const std = @import("std");

pub const MathError = error{LengthOverflow};

pub fn alignBackward(pos: usize, comptime alignment: usize) MathError!usize {
    comptime std.debug.assert(std.mem.isValidAlignGeneric(usize, alignment));
    return pos & ~(alignment - 1);
}

pub fn alignForward(pos: usize, comptime alignment: usize) MathError!usize {
    comptime std.debug.assert(std.mem.isValidAlignGeneric(usize, alignment));
    return alignBackward(pos + (alignment - 1), alignment);
}

pub fn usizeFromAnyInt(v: anytype) MathError!usize {
    return std.math.cast(usize, v) orelse error.LengthOverflow;
}

pub fn castUsize(comptime T: type, value: usize) MathError!T {
    return std.math.cast(T, value) orelse error.LengthOverflow;
}

