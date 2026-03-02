const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");
const root = @import("root.zig");

const Mem = meta.Mem;
const MergeOptions = root.MergeOptions;
pub const Context = meta.GetContext(MergeOptions);

/// This is used to recognize if types were returned by ToMerged.
/// This is done by assigning `pub const Underlying = MergedSignature;` inside an opaque
pub const MergedSignature = struct {
  /// The underlying type that was transformed
  T: type,
  /// The alignment of dynamic data, should be used by the Wrappers only
  _align: std.mem.Alignment = .@"1",
};

pub const Dynamic = Mem(.@"1");

/// A no-op opaque type that is used for static types (types with no dynamic / allocated data)
pub fn GetDirectMergedT(context: Context) type {
  const T = context.Type;
  return opaque {
    pub const Underlying = MergedSignature {.T = T};
    pub const STATIC = true; // Allow others to see if their child is static. This is required in slices
    pub inline fn write(noalias _: *T, noalias _: *Dynamic) void {}
    pub inline fn addDynamicSize(noalias _: *const T, noalias _: *usize) void {}
    pub inline fn repointer(noalias _: *T, noalias _: *Dynamic) void {}
  };
}

/// Converts a supplied pointer type to writable opaque. We change the pointer to point to the new memory for the pointed-to value
pub fn GetPointerMergedT(context: Context) type {
  if (!context.options.depointer) return GetDirectMergedT(context);

  const T = context.Type;
  const pi = @typeInfo(T).pointer;
  std.debug.assert(pi.size == .one);
  std.debug.assert(std.mem.Alignment.max(.fromByteUnits(pi.alignment), meta.max_align) == meta.max_align);
  if (!context.options.dereference_const_pointers and pi.is_const) return GetDirectMergedT(context);

  const Retval = opaque {
    pub const Underlying = MergedSignature {.T = T, ._align = if (next_context.seen_recursive >= 0) .fromByteUnits(pi.alignment) else std.mem.Alignment.max(.fromByteUnits(pi.alignment), Child.Underlying._align)};
    const Child = next_context.T(pi.child).merge();
    const next_context = context.see(T, @This());

    pub fn write(noalias _val: *T, noalias dynamic: *Dynamic) void {
      var ogptr = @intFromPtr(dynamic.ptr);
      const val: *meta.NonConstPointer(T, .one) = @ptrCast(@constCast(_val));
      const aligned_dynamic = dynamic.alignForward(pi.alignment);
      dynamic.* = aligned_dynamic.from(@sizeOf(pi.child)).alignForward(pi.alignment).from(0);

      const child_static: meta.NonConstPointer(T, .one) = @ptrCast(aligned_dynamic.ptr);
      child_static.* = val.*.*;
      Child.write(child_static, dynamic);

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }

      val.* = child_static; // TODO: figure out if this is ok
    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      size.* = std.mem.alignForward(usize, size.*, pi.alignment);
      size.* += @sizeOf(pi.child);
      size.* = std.mem.alignForward(usize, size.*, pi.alignment);
      Child.addDynamicSize(val.*, size);
    }

    pub fn repointer(noalias _val: *T, noalias dynamic: *Dynamic) void {
      var ogptr = @intFromPtr(dynamic.ptr);
      const val: *meta.NonConstPointer(T, .one) = @ptrCast(@constCast(_val));
      const aligned_dynamic = dynamic.alignForward(pi.alignment);
      dynamic.* = aligned_dynamic.from(@sizeOf(pi.child)).alignForward(pi.alignment).from(0);

      val.* = @ptrCast(aligned_dynamic.ptr); // TODO: figure out if this is ok
      Child.repointer(val.*, dynamic);

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

pub fn GetSliceMergedT(context: Context) type {
  if (!context.options.deslice) return GetDirectMergedT(context);

  const T = context.Type;
  const pi = @typeInfo(T).pointer;
  std.debug.assert(pi.size == .slice);
  std.debug.assert(std.mem.Alignment.max(.fromByteUnits(pi.alignment), meta.max_align) == meta.max_align);
  if (!context.options.dereference_const_pointers and pi.is_const) return GetDirectMergedT(context);

  const Retval = opaque {
    pub const Underlying = MergedSignature{.T = T, ._align = if (next_context.seen_recursive >= 0) .fromByteUnits(pi.alignment) else  std.mem.Alignment.max(.fromByteUnits(pi.alignment), Child.Underlying._align)};
    const Child = next_context.T(pi.child).merge();
    const SubStatic = @hasDecl(Child, "STATIC") and Child.STATIC;
    const next_context = context.see(T, @This());

    pub fn write(noalias _val: *T, noalias dynamic: *Dynamic) void {
      var ogptr = @intFromPtr(dynamic.ptr);
      const val: *meta.NonConstPointer(T, .slice) = @ptrCast(@constCast(_val));
      const aligned_dynamic = dynamic.alignForward(pi.alignment);
      const child_static_ptr: meta.NonConstPointer(T, .many) = @ptrCast(aligned_dynamic.ptr);
      const len = val.*.len;
      dynamic.* = aligned_dynamic.from(@sizeOf(pi.child) * len).alignForward(pi.alignment).from(0);

      // We can't write the dynamic data before static data as we would need to get the size of dynamic data first. Would is prettie inefficient
      @memcpy(child_static_ptr[0 .. len], val.*);
      val.*.ptr = child_static_ptr; // TODO: figure out if this is ok
      if (!SubStatic) { for (0 .. len) |i| Child.write(&val.*[i], dynamic); }

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }

    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      size.* = std.mem.alignForward(usize, size.*, pi.alignment);
      size.* += @sizeOf(pi.child) * val.*.len;
      size.* = std.mem.alignForward(usize, size.*, pi.alignment);
      if (!SubStatic) { for (0 .. val.*.len) |i| Child.addDynamicSize(&val.*[i], size); }
    }

    pub fn repointer(noalias _val: *T, noalias dynamic: *Dynamic) void {
      var ogptr = @intFromPtr(dynamic.ptr);
      const val: *meta.NonConstPointer(T, .slice) = @ptrCast(@constCast(_val));
      const aligned_dynamic = dynamic.alignForward(pi.alignment);
      const child_static_ptr: meta.NonConstPointer(T, .many) = @ptrCast(aligned_dynamic.ptr);
      const len = val.*.len;
      dynamic.* = aligned_dynamic.from(@sizeOf(pi.child) * len).alignForward(pi.alignment).from(0);

      val.*.ptr = @ptrCast(child_static_ptr); // TODO: figure out if this is ok
      if (!SubStatic) { for (0 .. val.*.len) |i| Child.repointer(&val.*[i], dynamic); }

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }
  };

  if (Retval.next_context.seen_recursive >= 0) return context.result_types[Retval.next_context.seen_recursive];
  return Retval;
}

pub fn GetArrayMergedT(context: Context) type {
  const T = context.Type;
  @setEvalBranchQuota(1000_000);
  const ai = @typeInfo(T).array;
  const Child = context.T(ai.child).merge();

  // If the child has no dynamic data, the entire array is static.
  // We can treat it as a no-op
  if (@hasDecl(Child, "STATIC") and Child.STATIC) return GetDirectMergedT(context);

  return opaque {
    pub const Underlying = MergedSignature{.T = T, ._align = if (context.see(ai.child, void).seen_recursive >= 0) .@"1" else Child.Underlying._align};

    pub fn write(noalias val: *T, noalias dynamic: *Dynamic) void {
      @setEvalBranchQuota(1000_000);
      var ogptr = @intFromPtr(dynamic.ptr);
      inline for (val) |*elem| Child.write(elem, dynamic);

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      @setEvalBranchQuota(1000_000);
      inline for (val) |*elem| Child.addDynamicSize(elem, size);
    }

    pub fn repointer(noalias val: *T, noalias dynamic: *Dynamic) void {
      @setEvalBranchQuota(1000_000);
      var ogptr = @intFromPtr(dynamic.ptr);
      inline for (val) |*elem| Child.repointer(elem, dynamic);

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }
  };
}

pub fn GetStructMergedT(context: Context) type {
  const T = context.Type;
  @setEvalBranchQuota(1000_000);

  const si = @typeInfo(T).@"struct";
  const ProcessedField = struct {
    original: std.builtin.Type.StructField,
    merged: type,
  };

  const Retval = opaque {
    pub const Underlying = MergedSignature{.T = T, ._align = blk: {
      var max: std.mem.Alignment = if (context.see(fields[0].original.type, void).seen_recursive >= 0) .@"1" else fields[0].merged.Underlying._align;
      for (fields[1..]) |f| max = max.max(if (context.see(f.original.type, void).seen_recursive >= 0) .@"1" else f.merged.Underlying._align);
      break :blk max;
    }};
    const STATIC = dynamic_field_count == 0;

    const fields = blk: {
      @setEvalBranchQuota(1000_000);
      var pfields: [si.fields.len]ProcessedField = undefined;
      for (si.fields, 0..) |f, i| {
        pfields[i] = .{
          .original = f,
          .merged = context.T(f.type).merge(),
        };
      }
      break :blk pfields;
    };

    const dynamic_field_count = blk: {
      @setEvalBranchQuota(1000_000);
      var dyn_count: usize = 0;
      for (fields) |f| {
        if (@hasDecl(f.merged, "STATIC") and f.merged.STATIC) continue;
        dyn_count += 1;
      }
      break :blk dyn_count;
    };

    /// The field with max alignment requirement for dynamic data is in first place
    const sorted_dynamic_fields = blk: {
      @setEvalBranchQuota(1000_000);
      var dyn_fields: [dynamic_field_count]ProcessedField = undefined;
      var i: usize = 0;
      for (fields) |f| {
        if (@hasDecl(f.merged, "STATIC") and f.merged.STATIC) continue;
        dyn_fields[i] = f;
        i += 1;
      }

      std.debug.assert(i == dynamic_field_count);
      std.mem.sortContext(0, dyn_fields.len, struct {
        fields: []ProcessedField,

        fn greaterThan(self: @This(), lhs: usize, rhs: usize) bool {
          const ls = self.fields[lhs].merged.Underlying;
          const rs = self.fields[rhs].merged.Underlying;
          if (ls._align != rs._align) return @intFromEnum(ls._align) > @intFromEnum(rs._align);
          return false;
        }

        pub const lessThan = greaterThan;

        pub fn swap(self: @This(), lhs: usize, rhs: usize) void {
          const temp = self.fields[lhs];
          self.fields[lhs] = self.fields[rhs];
          self.fields[rhs] = temp;
        }
      }{ .fields = &dyn_fields });
      break :blk dyn_fields;
    };

    pub fn write(noalias val: *T, noalias dynamic: *Dynamic) void {
      @setEvalBranchQuota(1000_000);
      var ogptr = @intFromPtr(dynamic.ptr);
      inline for (sorted_dynamic_fields) |f| {
        f.merged.write(&@field(val, f.original.name), dynamic);
      }

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      @setEvalBranchQuota(1000_000);
      inline for (sorted_dynamic_fields) |f| {
        f.merged.addDynamicSize(&@field(val, f.original.name), size);
      }
    }

    pub fn repointer(noalias val: *T, noalias dynamic: *Dynamic) void {
      @setEvalBranchQuota(1000_000);
      var ogptr = @intFromPtr(dynamic.ptr);
      inline for (sorted_dynamic_fields) |f| {
        f.merged.repointer(&@field(val, f.original.name), dynamic);
      }

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }
  };

  if (Retval.STATIC) return GetDirectMergedT(context);
  return Retval;
}

pub fn GetOptionalMergedT(context: Context) type {
  const T = context.Type;
  const oi = @typeInfo(T).optional;
  const Child = context.T(oi.child).merge();
  if (@hasDecl(Child, "STATIC") and Child.STATIC) return GetDirectMergedT(context);

  return opaque {
    pub const Underlying = MergedSignature{.T = T, ._align = if (context.see(oi.child, void).seen_recursive >= 0) .@"1" else Child.Underlying._align};

    pub fn write(noalias val: *T, noalias dynamic: *Dynamic) void {
      if (val.* != null) {
        var ogptr = @intFromPtr(dynamic.ptr);
        Child.write(&(val.*.?), dynamic);

        if (builtin.mode == .Debug) {
          addDynamicSize(val, &ogptr);
          std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
        }
      }
    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      if (val.* != null) Child.addDynamicSize(&(val.*.?), size);
    }

    pub fn repointer(noalias val: *T, noalias dynamic: *Dynamic) void {
      if (val.* != null) {
        var ogptr = @intFromPtr(dynamic.ptr);
        Child.repointer(&(val.*.?), dynamic);

        if (builtin.mode == .Debug) {
          addDynamicSize(val, &ogptr);
          std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
        }
      }
    }
  };
}

pub fn GetErrorUnionMergedT(context: Context) type {
  const T = context.Type;
  const ei = @typeInfo(T).error_union;
  const Payload = ei.payload;

  const Child = context.T(Payload).merge();
  if (@hasDecl(Child, "STATIC") and Child.STATIC) return GetDirectMergedT(context);

  return opaque {
    pub const Underlying = MergedSignature{.T = T, ._align = if (context.see(Payload, void).seen_recursive >= 0) .@"1" else Child.Underlying._align};

    pub fn write(noalias val: *T, noalias dynamic: *Dynamic) void {
      var ogptr = @intFromPtr(dynamic.ptr);
      Child.write(&(val.* catch return), dynamic);

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      Child.addDynamicSize(&(val.* catch return), size);
    }

    pub fn repointer(noalias val: *T, noalias dynamic: *Dynamic) void {
      var ogptr = @intFromPtr(dynamic.ptr);
      Child.repointer(&(val.* catch return), dynamic);

      if (builtin.mode == .Debug) {
        addDynamicSize(val, &ogptr);
        std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
      }
    }
  };
}

pub fn GetUnionMergedT(context: Context) type {
  const T = context.Type;
  const ui = @typeInfo(T).@"union";

  const ProcessedField = struct {
    original: std.builtin.Type.UnionField,
    merged: type,
  };

  const Retval = opaque {
    pub const Underlying = MergedSignature{.T = T, ._align = blk: {
      var max: std.mem.Alignment = if (context.see(fields[0].original.type, void).seen_recursive >= 0) .@"1" else fields[0].merged.Underlying._align;
      for (fields[1..]) |f| max = max.max(if (context.see(f.original.type, void).seen_recursive >= 0) .@"1" else f.merged.Underlying._align);
      break :blk max;
    }};
    const TagType = ui.tag_type orelse @compileError("Union '" ++ @typeName(T) ++ "' has no tag type");

    const STATIC = blk: {
      for (fields) |f| {
        if (@hasDecl(f.merged, "STATIC") and f.merged.STATIC) continue;
        break :blk false;
      }
      break :blk true;
    };

    const fields = blk: {
      var pfields: [ui.fields.len]ProcessedField = undefined;
      for (ui.fields, 0..) |f, i| pfields[i] = .{
        .original = f,
        .merged = context.T(f.type).merge(),
      };
      break :blk pfields;
    };

    pub fn write(noalias val: *T, noalias dynamic: *Dynamic) void {
      const active_tag = std.meta.activeTag(val.*);

      inline for (fields) |f| {
        const field_as_tag = @field(TagType, f.original.name);
        if (field_as_tag == active_tag) {
          var ogptr = @intFromPtr(dynamic.ptr);
          f.merged.write(&@field(val, f.original.name), dynamic);

          if (builtin.mode == .Debug) {
            addDynamicSize(val, &ogptr);
            std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
          }
          return;
        }
      }
      unreachable;
    }

    pub fn addDynamicSize(noalias val: *const T, noalias size: *usize) void {
      const active_tag = std.meta.activeTag(val.*);

      inline for (fields) |f| {
        const field_as_tag = @field(TagType, f.original.name);
        if (field_as_tag == active_tag) {
          f.merged.addDynamicSize(&@field(val, f.original.name), size);
          return;
        }
      }
      unreachable;
    }

    pub fn repointer(noalias val: *T, noalias dynamic: *Dynamic) void {
      const active_tag = std.meta.activeTag(val.*);

      inline for (fields) |f| {
        const field_as_tag = @field(TagType, f.original.name);
        if (field_as_tag == active_tag) {
          var ogptr = @intFromPtr(dynamic.ptr);
          f.merged.repointer(&@field(val, f.original.name), dynamic);

          if (builtin.mode == .Debug) {
            addDynamicSize(val, &ogptr);
            std.debug.assert(@intFromPtr(dynamic.ptr) == ogptr);
          }
          return;
        } 
      }
      unreachable;
    }
  };

  if (Retval.STATIC) return GetDirectMergedT(context);
  if (ui.tag_type == null) @compileError("Cannot merge untagged union with dynamic data: " ++ @typeName(T));
  return Retval;
}
