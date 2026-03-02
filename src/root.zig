const std = @import("std");
const meta = @import("meta.zig");
const builtin = @import("builtin");
pub const SerializationFunctions = @import("serialization_functions.zig");
const SF = SerializationFunctions;
const Context = SF.Context;

/// Options to control how merging of a type is performed
pub const MergeOptions = struct {
  /// Whether to dereference pointers or use them by value
  depointer: bool = true,
  /// What is the maximum number of expansion of slices that can be done
  /// for example in a recursive structure or nested slices
  ///
  /// eg.
  /// If we have val: []u8, and deslice = false, we will write only val.ptr + val.len
  /// If we have val: []u8, and deslice = true, we will write all the characters in this block as well as val.ptr + val.len
  /// Nested deslicing is also supported. For example, if we have val: [][]u8, and deslice = true, we will write all the characters
  ///   + list of pointers & lengths (pointers will point to slice where the strings are stored) + the top pointer & length
  deslice: bool = true,
  /// Serialize unknown pointers (C / Many / opaque pointers) as usize. This makes the data non-movable and thus is disabled by default.
  serialize_unknown_pointer_as_usize: bool = false,
  /// Dereference constant pointers. (The original pointer is not modified, the value is copied first, then modified)
  /// Treat pointers to constant when this is false.
  dereference_const_pointers: bool = true,
};

pub fn ToMergedT(context: SF.Context) type {
  const T = context.Type;
  @setEvalBranchQuota(1000_000);
  return switch (@typeInfo(T)) {
    .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal => {
      @compileError("Type '" ++ @tagName(std.meta.activeTag(@typeInfo(T))) ++ "' is not mergeable\n");
    },
    .void, .bool, .int, .float, .vector, .error_set, .null, .@"enum" => SF.GetDirectMergedT(context),
    .pointer => |pi| switch (pi.size) {
      .many, .c => if (context.options.serialize_unknown_pointer_as_usize) SF.GetDirectMergedT(context) else {
        @compileError(@tagName(pi.size) ++ " pointer cannot be serialized for type " ++ @typeName(T) ++ ", consider setting serialize_many_pointer_as_usize to true\n");
      },
      .one => switch (@typeInfo(pi.child)) {
        .@"opaque" => if (@hasDecl(pi.child, "Underlying") and @TypeOf(pi.child.Underlying) == SF.MergedSignature) pi.child else {
          @compileError("A non-mergeable opaque " ++ @typeName(pi.child) ++ " was provided to `ToMergedT`\n");
        },
        else => SF.GetPointerMergedT(context),
      },
      .slice => SF.GetSliceMergedT(context),
    },
    .array => SF.GetArrayMergedT(context),
    .@"struct" => SF.GetStructMergedT(context),
    .optional => SF.GetOptionalMergedT(context),
    .error_union => SF.GetErrorUnionMergedT(context),
    .@"union" => SF.GetUnionMergedT(context),
    .@"opaque" => if (@hasDecl(T, "Underlying") and @TypeOf(T.Underlying) == SF.MergedSignature) T else {
      @compileError("A non-mergeable opaque " ++ @typeName(T) ++ " was provided to `ToMergedT`\n");
    },
  };
}

/// A generic wrapper that manages the memory for a merged object.
pub fn WrapConverted(_T: type, MergedT: type) type {
  std.debug.assert(_T == MergedT.Underlying.T);
  return struct {
    pub const Underlying = MergedT;
    memory: []align(alignment.toByteUnits()) u8,

    pub const T = _T;
    pub const STATIC = @hasDecl(MergedT, "STATIC") and MergedT.STATIC;
    pub const alignment = std.mem.Alignment.fromByteUnits(@alignOf(T)).max(MergedT.Underlying._align);

    /// Allocates memory and merges the initial value into a self-managed buffer.
    /// The Wrapper instance owns the memory and must be de-initialized with `deinit`.
    ///
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn init(noalias val: *const T, gpa: std.mem.Allocator) !@This() {
      var retval: @This() = .{ .memory = try gpa.alignedAlloc(u8, alignment, getSize(val)) };
      retval.setAssert(val);
      return retval;
    }

    /// Returns the total size that would be required to store this value
    ///
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn getSize(value: *const T) usize {
      var size: usize = @sizeOf(T);
      if (!STATIC) MergedT.addDynamicSize(value, &size);
      return size;
    }

    /// Returns a mutable pointer to the merged data, allowing modification. The pointer is valid as long as the Wrapper is not de-initialized.
    pub fn get(self: *const @This()) *T {
      return @ptrCast(self.memory.ptr);
    }

    /// Creates a new, independent Wrapper containing a deep copy of the data.
    pub fn clone(noalias self: *const @This(), gpa: std.mem.Allocator) !@This() {
      // We could return try @This().init(allocator, self.get());
      // But that would be 2 operations. getSize and init. this is only 1 operation; repointer
      const retval: @This() = .{ .memory = try gpa.alignedAlloc(u8, alignment, self.memory.len)};
      @memcpy(retval.memory, self.memory);
      retval.repointer();
      return retval;
    }

    /// Set a new value into the wrapper. Invalidates any references to the old value
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn set(self: *@This(), gpa: std.mem.Allocator, value: *const T) !void {
      const new_len = getSize(value);
      self.memory = gpa.remap(self.memory, new_len) orelse blk: {
        gpa.free(self.memory);
        break :blk try gpa.alignedAlloc(u8, alignment, new_len);
      };
      self.setAssert(value);
    }

    /// Set a new value into the wrapper, asserting that underlying allocation can hold it. Invalidates any references to the old value
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn setAssert(self: *const @This(), value: *const T) void {
      if (builtin.mode == .Debug) { // debug.assert alone may not be optimized out
        std.debug.assert(getSize(value) <= self.memory.len);
      }

      self.get().* = value.*;
      var dynamic_buffer: SF.Dynamic = .init(self.memory[@sizeOf(T)..]);
      MergedT.write(self.get(), &dynamic_buffer);

      if (builtin.mode == .Debug) {
        std.debug.assert(@intFromPtr(dynamic_buffer.ptr) <= @intFromPtr(self.memory[@sizeOf(T)..].ptr) + getSize(value));
      }
    }

    /// Updates the internal pointers within the merged data structure. This is necessary
    /// if the underlying `memory` buffer is moved (e.g., after a memcpy).
    pub fn repointer(self: *const @This()) void {
      if (STATIC) return;
      var dynamic = SF.Dynamic.init(self.memory[@sizeOf(T)..]);
      MergedT.repointer(self.get(), &dynamic);
      if (builtin.mode == .Debug) {
        std.debug.assert(@intFromPtr(dynamic.ptr) <= @intFromPtr(self.memory[@sizeOf(T)..].ptr) + getSize(self.get()));
      }
    }

    /// Frees the memory owned by the Wrapper.
    pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
      gpa.free(self.memory);
    }
  };
}

pub fn Wrapper(T: type, options: MergeOptions) type {
  return WrapConverted(T, Context.init(T, options, ToMergedT));
}

pub fn DynamicWrapConverted(_T: type, MergedT: type) type {
  if (@hasDecl(MergedT, "STATIC") and MergedT.STATIC) {
    @compileError("Dynamic wrapper for static struct does not make any sense");
  }

  return struct {
    pub const Underlying = MergedT;
    memory: []align(alignment.toByteUnits()) u8,

    pub const T = _T;
    pub const alignment = MergedT.Underlying._align;

    /// Allocates memory and merges the initial value into a self-managed buffer. The Wrapper instance owns the memory and must be de-initialized with `deinit`.
    /// buffer is allocated only for the dynamic data; thus the passed in instance is modified
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn init(noalias val: *T, gpa: std.mem.Allocator) !@This() {
      var retval: @This() = .{ .memory = try gpa.alignedAlloc(u8, alignment, getSize(val)) };
      retval.setAssert(val);
      return retval;
    }

    /// Returns the total size that would be required to store this value
    /// Expects there to be no data cycles
    pub fn getSize(value: *const T) usize {
      var size: usize = 0;
      MergedT.addDynamicSize(value, &size);
      return size;
    }

    /// Creates a new, independent Wrapper containing a deep copy of the data.
    /// `new_val` is modified in-place; is stores then pointers inside of the returned wrapper
    pub fn clone(self: *const @This(), old_val: *const T, gpa: std.mem.Allocator) !std.meta.Tuple(&.{T, @This()}) {
      // We could return try @This().init(allocator, self.get());
      // But that would be 2 operations. getSize and init. this is only 1 operation; repointer
      const retval: @This() = .{ .memory = try gpa.alignedAlloc(u8, alignment, self.memory.len)};
      @memcpy(retval.memory, self.memory);
      var new_val = old_val.*;
      retval.repointer(&new_val);
      return .{new_val, retval};
    }

    /// Set a new value into the wrapper. Invalidates any references to the old value
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn set(self: *@This(), gpa: std.mem.Allocator, value: *T) !void {
      const new_len = getSize(value);
      self.memory = gpa.remap(self.memory, new_len) orelse blk: {
        gpa.free(self.memory);
        break :blk try gpa.alignedAlloc(u8, alignment, new_len);
      };
      return self.setAssert(value);
    }

    /// Set a new value into the wrapper, asserting that underlying allocation can hold it. Invalidates any references to the old value
    /// NOTE: We expects there to be no data cycles [No *A.b pointing to *B and *B.a pointing to *A]
    pub fn setAssert(self: *const @This(), val: *T) void {
      if (builtin.mode == .Debug) { // debug.assert alone may not be optimized out
        std.debug.assert(getSize(val) <= self.memory.len);
      }

      var dynamic_buffer = SF.Dynamic.init(self.memory);
      MergedT.write(val, &dynamic_buffer);

      if (builtin.mode == .Debug) {
        std.debug.assert(@intFromPtr(dynamic_buffer.ptr) <= @intFromPtr(self.memory.ptr) + getSize(val));
      }
    }

    /// Updates the internal pointers within the merged data structure. This is necessary
    /// if the underlying `memory` buffer is moved (e.g., after a memcpy).
    pub fn repointer(self: *const @This(), val: *T) void {
      var dynamic = SF.Dynamic.init(self.memory);
      MergedT.repointer(val, &dynamic);
      if (builtin.mode == .Debug) {
        std.debug.assert(@intFromPtr(dynamic.ptr) <= @intFromPtr(self.memory.ptr) + getSize(val));
      }
    }

    /// Frees the memory owned by the Wrapper.
    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.memory);
    }
  };
}

/// Returns void if the underlying type has NO dynamic data
pub fn DynamicWrapper(T: type, options: MergeOptions) type {
  const MergedT = Context.init(T, options, ToMergedT);
  if (@hasDecl(MergedT, "STATIC") and MergedT.STATIC) return void;
  return DynamicWrapConverted(T, MergedT);
}

test {
  std.testing.refAllDeclsRecursive(@This());
  std.testing.refAllDeclsRecursive(meta);
  std.testing.refAllDeclsRecursive(SF);
}
