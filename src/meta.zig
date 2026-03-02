const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const testing = std.testing;

pub const max_align = blk: {
  const fields = @typeInfo(std.mem.Alignment).@"enum".fields;
  var max: std.mem.Alignment = .@"1";
  for (fields) |f| max = std.mem.Alignment.max(max, @enumFromInt(f.value));
  break :blk max;
};

/// Given a function type, get the return type
pub fn FnReturnType(T: type) type {
  return switch (@typeInfo(T)) {
    .@"fn" => |info| info.return_type.?,
    else => @compileError("Expected function type, got " ++ @typeName(T)),
  };
}

/// We dont need the length of the allocations but they are useful for debugging
/// This is a helper type designed to help with catching errors
fn MemExtra(_alignment: std.mem.Alignment, _need_len: bool) type {
  const keep_len = builtin.mode == .Debug or _need_len;
  return struct {
    ptr: [*]align(alignment) u8,
    /// We only use this in debug mode
    len: if (keep_len) usize else void,

    pub const alignment = _alignment.toByteUnits();
    pub const need_len = _need_len;

    pub fn init(v: []align(alignment) u8) @This() {
      return .{ .ptr = v.ptr, .len = if (keep_len) v.len else {} };
    }

    pub inline fn from(self: @This(), index: usize) MemExtra(.@"1", _need_len) {
      if (builtin.mode == .Debug and index > self.len) {
        std.debug.panic("Index {d} is out of bounds for slice of length {d}\n", .{ index, self.len });
      }
      return .{ .ptr = self.ptr + index, .len = if (keep_len) self.len - index else {} };
    }

    pub fn assertAligned(self: @This(), comptime new_alignment: usize) MemExtra(.fromByteUnits(new_alignment), _need_len) {
      if (builtin.mode == .Debug) std.debug.assert(std.mem.isAligned(@intFromPtr(self.ptr), new_alignment));
      return .{ .ptr = @alignCast(self.ptr), .len = self.len };
    }

    pub fn alignForward(self: @This(), comptime new_alignment: usize) MemExtra(.fromByteUnits(new_alignment), _need_len) {
      const aligned_ptr = std.mem.alignForward(usize, @intFromPtr(self.ptr), new_alignment);
      return .{
        .ptr = @ptrFromInt(aligned_ptr),
        .len = self.len - (aligned_ptr - @intFromPtr(self.ptr)) // Underflow => user error
      };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
      if (keep_len) try writer.print("{any}", .{self.ptr[0..self.len]})
      else try writer.print("{s}.{{ ptr = {any}}}", .{ @typeName(@This()) , self.ptr });
    }
  };
}

pub fn GetContext(Options: type) type {
  return struct {
    Type: type,
    /// What should be the alignment of the type being merged
    align_hint: ?std.mem.Alignment,
    /// The types that have been seen so far
    seen_types: []const type,
    /// The types that have been merged so far (each corresponding to a seen type)
    result_types: []const type,
    /// If we have seen a type passed to .see before, this will give it's index, otherwise -1
    seen_recursive: comptime_int,
    /// The options used by the merging function
    options: Options,
    /// The function that will be used to merge a type
    merge_fn: fn (context: @This()) type,

    pub fn init(Type: type, options: Options, merge_fn: fn (context: @This()) type) type {
      const self = @This() {
        .Type = Type,
        .align_hint = null,
        .seen_types = &.{},
        .result_types = &.{},
        .options = options,
        .seen_recursive = -1,
        .merge_fn = merge_fn,
      };

      return self.merge();
    }

    pub fn merge(self: @This()) type {
      return self.merge_fn(self);
    }

    pub fn see(self: @This(), new_T: type, Result: type) @This() { // Yes we can do this, Zig is f****ing awesome
      const have_seen = comptime blk: {
        for (self.seen_types, 0..) |t, i| if (new_T == t) break :blk i;
        break :blk -1;
      };

      var retval = self;
      retval.seen_types = self.seen_types ++ [1]type{new_T};
      retval.result_types = self.result_types ++ [1]type{Result};
      retval.seen_recursive = have_seen;
      return retval;
    }

    pub fn reop(self: @This(), options: Options) @This() {
      var retval = self;
      retval.options = options;
      return retval;
    }

    pub fn T(self: @This(), comptime new_T: type) @This() {
      var retval = self;
      retval.Type = new_T;
      return retval;
    }
  };
}

pub fn NonConstPointer(T: type, size: std.builtin.Type.Pointer.Size) type {
  var info = @typeInfo(T).pointer;
  info.is_const = false;
  info.size = size;
  return @Type(.{.pointer = info});
}

