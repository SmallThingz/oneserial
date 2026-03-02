const std = @import("std");
pub const SerializationFunctions = @import("serialization_functions.zig");

/// Global wire length type. Keep a single definition here.
pub const Size = u32;

/// Reserved for future behavior switches.
pub const MergeOptions = struct {};

pub const ValidationError = SerializationFunctions.ValidationError;
pub const SerializeError = SerializationFunctions.SerializeError;
pub const DeserializeError = SerializationFunctions.DeserializeError;

pub fn Converter(comptime T: type, options: MergeOptions) type {
    _ = options;
    return SerializationFunctions.Converter(T);
}

pub fn Wrapper(comptime T: type, options: MergeOptions) type {
    return Converter(T, options).Wrapper;
}

pub fn Untrusted(comptime T: type, options: MergeOptions) type {
    return Converter(T, options).Untrusted;
}

pub fn Trusted(comptime T: type, options: MergeOptions) type {
    return Converter(T, options).Trusted;
}

pub fn serializeAlloc(comptime T: type, options: MergeOptions, value: *const T, gpa: std.mem.Allocator) SerializeError![]u8 {
    return Converter(T, options).serializeAlloc(value, gpa);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(SerializationFunctions);
}
