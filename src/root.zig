const std = @import("std");
const builtin = @import("builtin");
pub const SerializationFunctions = @import("serialization_functions.zig");

/// Global wire length type. Keep a single definition here.
pub const Size = u32;

/// Reserved for future behavior switches.
pub const MergeOptions = struct {
    /// Wire endianness for serialization and view decoding.
    /// Defaults to native-endian for current behavior compatibility.
    endian: std.builtin.Endian = builtin.target.cpu.arch.endian(),
};

pub const ValidationError = SerializationFunctions.ValidationError;
pub const SerializeError = SerializationFunctions.SerializeError;
pub const DeserializeError = SerializationFunctions.DeserializeError;

pub fn Converter(comptime T: type, comptime options: MergeOptions) type {
    return SerializationFunctions.Converter(T, options.endian);
}

pub fn Wrapper(comptime T: type, comptime options: MergeOptions) type {
    return Converter(T, options).Wrapper;
}

pub fn Untrusted(comptime T: type, comptime options: MergeOptions) type {
    return Converter(T, options).Untrusted;
}

pub fn Trusted(comptime T: type, comptime options: MergeOptions) type {
    return Converter(T, options).Trusted;
}

pub fn serializeAlloc(
    comptime T: type,
    comptime options: MergeOptions,
    value: *const T,
    gpa: std.mem.Allocator,
) SerializeError!SerializationFunctions.SerializeBytes(T) {
    return Converter(T, options).serializeAlloc(value, gpa);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(SerializationFunctions);
}
