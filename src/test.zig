const std = @import("std");
const root = @import("root.zig");
const meta = @import("meta.zig");
const SF = @import("serialization_functions.zig");
const testing = std.testing;
const MergeOptions = root.MergeOptions;
const Context = SF.Context;

test {
  std.testing.refAllDeclsRecursive(@This());
}

fn expectEqual(expected: anytype, actual: anytype) error{TestExpectedEqual}!void {
  const print = std.debug.print;

  if (std.meta.activeTag(@typeInfo(@TypeOf(actual))) != std.meta.activeTag(@typeInfo(@TypeOf(expected)))) {
    print("expected type {s}, found type {s}\n", .{ @typeName(@TypeOf(expected)), @typeName(@TypeOf(actual)) });
    return error.TestExpectedEqual;
  }

  switch (@typeInfo(@TypeOf(actual))) {
    .noreturn, .@"opaque", .frame, .@"anyframe", => @compileError("value of type " ++ @typeName(@TypeOf(actual)) ++ " encountered"),

    .void => return,

    .type => {
      if (actual != expected) {
        print("expected type {s}, found type {s}\n", .{ @typeName(expected), @typeName(actual) });
        return error.TestExpectedEqual;
      }
    },

    .bool, .int, .float, .comptime_float, .comptime_int, .enum_literal, .@"enum", .@"fn", .error_set => {
      if (actual != expected) {
        print("expected {}, found {}\n", .{ expected, actual });
        return error.TestExpectedEqual;
      }
    },

    .pointer => |pointer| {
      switch (pointer.size) {
        .one, .c => {
          if (actual == expected) {
            return;
          }
          return expectEqual(actual.*, expected.*);
        },
        .many => {
          if (actual != expected) {
            print("expected pointers to be the same for {s}\n", .{ @typeName(@TypeOf(actual)) });
            print("expected: {any}\nactual: {any}\n", .{ expected, actual });
            return error.TestExpectedEqual;
          }
        },
        .slice => {
          if (actual.len != expected.len) {
            print("expected slice len {}, found {}\n", .{ expected.len, actual.len });
            print("expected: {any}\nactual: {any}\n", .{ expected, actual });
            return error.TestExpectedEqual;
          }
          if (actual.ptr == expected.ptr) {
            // std.debug.dumpCurrentStackTrace(null);
            // print("slices are same for {s}\n", .{ @typeName(@TypeOf(actual)) });
            return;
          }
          for (actual, expected, 0..) |va, ve, i| {
            expectEqual(va, ve) catch |e| {
              print("index {d} incorrect.\nexpected:: {any}\nfound:: {any}\n", .{ i, expected[i], actual[i] });
              return e;
            };
          }
        },
      }
    },

    .array => |array| {
      inline for (0..array.len) |i| {
        expectEqual(expected[i], actual[i]) catch |e| {
          print("index {d} incorrect.\nexpected:: {any}\nfound:: {any}\n", .{ i, expected[i], actual[i] });
          return e;
        };
      }
    },

    .vector => |info| {
      var i: usize = 0;
      while (i < info.len) : (i += 1) {
        if (!std.meta.eql(expected[i], actual[i])) {
          print("index {d} incorrect.\nexpected:: {any}\nfound:: {any}\n", .{ i, expected[i], actual[i] });
          return error.TestExpectedEqual;
        }
      }
    },

    .@"struct" => |structType| {
      inline for (structType.fields) |field| {
        errdefer print("field `{s}` incorrect\n", .{ field.name });
        try expectEqual(@field(expected, field.name), @field(actual, field.name));
      }
    },

    .@"union" => |union_info| {
      if (union_info.tag_type == null) @compileError("Unable to compare untagged union values for type " ++ @typeName(@TypeOf(actual)));
      const Tag = std.meta.Tag(@TypeOf(expected));
      const expectedTag = @as(Tag, expected);
      const actualTag = @as(Tag, actual);

      try expectEqual(expectedTag, actualTag);

      switch (expected) {
        inline else => |val, tag| try expectEqual(val, @field(actual, @tagName(tag))),
      }
    },

    .optional => {
      if (expected) |expected_payload| {
        if (actual) |actual_payload| {
          try expectEqual(expected_payload, actual_payload);
        } else {
          print("expected {any}, found null\n", .{expected_payload});
          return error.TestExpectedEqual;
        }
      } else {
        if (actual) |actual_payload| {
          print("expected null, found {any}\n", .{actual_payload});
          return error.TestExpectedEqual;
        }
      }
    },

    .error_union => {
      if (expected) |expected_payload| {
        if (actual) |actual_payload| {
          try expectEqual(expected_payload, actual_payload);
        } else |actual_err| {
          print("expected {any}, found {}\n", .{ expected_payload, actual_err });
          return error.TestExpectedEqual;
        }
      } else |expected_err| {
        if (actual) |actual_payload| {
          print("expected {}, found {any}\n", .{ expected_err, actual_payload });
          return error.TestExpectedEqual;
        } else |actual_err| {
          try expectEqual(expected_err, actual_err);
        }
      }
    },

    else => @compileError("Unsupported type in expectEqual: " ++ @typeName(@TypeOf(expected))),
  }
}

const ToMergedT = root.ToMergedT;

test {
  std.testing.refAllDeclsRecursive(@This());
  std.testing.refAllDeclsRecursive(root);
}

fn testMergingDemerging(_value: anytype, comptime options: MergeOptions) !void {
  var value = _value;
  const T = @TypeOf(value);
  const MergedT = Context.init(T, options, ToMergedT);

  const Wrapped = root.WrapConverted(T, MergedT);
  var wrapped: Wrapped = undefined;

  const total_size: usize = Wrapped.getSize(&value);

  const static_size = @sizeOf(T);
  const alignment: comptime_int = comptime Wrapped.alignment.toByteUnits();
  var buffer: [static_size + 4096]u8 align(alignment) = undefined;
  if (total_size > buffer.len) {
    std.log.err("buffer too small for test. need {d}, have {d}", .{ total_size, buffer.len });
    return error.NoSpaceLeft;
  }

  wrapped.memory = @ptrCast(@alignCast(buffer[0..total_size]));
  wrapped.setAssert(&value);
  expectEqual(&value, wrapped.get()) catch |e| {
    std.log.warn("memory: {any}", .{wrapped.memory});
    std.log.err("original: {any}\nvalue: {any}", .{ value, wrapped.get() });
    return e;
  };

  var copy = try wrapped.clone(testing.allocator);
  defer copy.deinit(testing.allocator);

  @memset(wrapped.memory, 69);
  expectEqual(&value, copy.get()) catch |e| {
    std.log.warn("memory: {any}", .{copy.memory});
    std.log.err("original: {any}\nvalue: {any}", .{ value, copy.get() });
    return e;
  };
}

fn testMerging(value: anytype) !void {
  try testMergingDemerging(value, .{});
}

test "primitives" {
  try testMerging(@as(u32, 42));
  try testMerging(@as(f64, 123.456));
  try testMerging(@as(bool, true));
  try testMerging(@as(void, {}));
}

test "pointers" {
  var x: u64 = 12345;
  try testMerging(&x);
  try testMergingDemerging(@as(*u64, &x), .{.depointer = false});
}

test "slices" {
  // primitive
  try testMerging(@as([]const u8, "hello zig"));

  // struct
  const Point = struct { x: u8, y: u8 };
  try testMerging(@as([]const Point, &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } }));

  // nested
  try testMerging(@as([]const []const u8, &.{"hello", "world", "zig", "rocks"}));

  // empty
  try testMerging(@as([]const u8, &.{}));
  try testMerging(@as([]const []const u8, &.{}));
  try testMerging(@as([]const []const u8, &.{"", "a", ""}));
}

test "arrays" {
  // primitive
  try testMerging([4]u8{ 1, 2, 3, 4 });

  // struct array
  const Point = struct { x: u8, y: u8 };
  try testMerging([2]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } });

  // nested arrays
  try testMerging([2][2]u8{ .{ 1, 2 }, .{ 3, 4 } });

  // empty
  try testMerging([0]u8{});
}

test "structs" {
  // Simple
  const Point = struct { x: i32, y: i32 };
  try testMerging(Point{ .x = -10, .y = 20 });

  // Nested
  const Line = struct { p1: Point, p2: Point };
  try testMerging(Line{ .p1 = .{ .x = 1, .y = 2 }, .p2 = .{ .x = 3, .y = 4 } });
}

test "enums" {
  // Simple
  const Color = enum { red, green, blue };
  try testMerging(Color.green);
}

test "optional" {
  // value
  var x: ?i32 = 42;
  try testMerging(x);
  x = null;
  try testMerging(x);

  // pointer
  var y: i32 = 123;
  var opt_ptr: ?*i32 = &y;
  try testMerging(opt_ptr);

  opt_ptr = null;
  try testMerging(opt_ptr);
}

test "error_unions" {
  const MyError = error{Oops};
  var eu: MyError!u32 = 123;
  try testMerging(eu);
  eu = MyError.Oops;
  try testMerging(eu);
}

test "unions" {
  const Payload = union(enum) {
    a: u32,
    b: bool,
    c: void,
  };
  try testMerging(Payload{ .a = 99 });
  try testMerging(Payload{ .b = false });
  try testMerging(Payload{ .c = {} });
}

test "complex struct" {
  const Nested = struct {
    c: u4,
    d: bool,
  };

  const KitchenSink = struct {
    a: i32,
    b: []const u8,
    c: [2]Nested,
    d: ?*const i32,
    e: f32,
  };

  var value = KitchenSink{
    .a = -1,
    .b = "dynamic slice",
    .c = .{ .{ .c = 1, .d = true }, .{ .c = 2, .d = false } },
    .d = &@as(i32, 42),
    .e = 3.14,
  };

  try testMerging(value);

  value.b = "";
  try testMerging(value);

  value.d = null;
  try testMerging(value);
}

test "slice of complex structs" {
  const Item = struct {
    id: u64,
    name: []const u8,
    is_active: bool,
  };

  const items = [_]Item{
    .{ .id = 1, .name = "first", .is_active = true },
    .{ .id = 2, .name = "second", .is_active = false },
    .{ .id = 3, .name = "", .is_active = true },
  };

  try testMerging(items[0..]);
}

test "complex composition" {
  const Complex1 = struct {
    a: u32,
    b: u32,
    c: u32,
  };

  const Complex2 = struct {
    a: Complex1,
    b: []const Complex1,
  };

  const SuperComplex = struct {
    a: Complex1,
    b: Complex2,
    c: []const union(enum) {
      a: Complex1,
      b: Complex2,
    },
  };

  const value = SuperComplex{
    .a = .{ .a = 1, .b = 2, .c = 3 },
    .b = .{
      .a = .{ .a = 4, .b = 5, .c = 6 },
      .b = &.{.{ .a = 7, .b = 8, .c = 9 }},
    },
    .c = &.{
      .{ .a = .{ .a = 10, .b = 11, .c = 12 } },
      .{ .b = .{ .a = .{ .a = 13, .b = 14, .c = 15 }, .b = &.{.{ .a = 16, .b = 17, .c = 18 }} } },
    },
  };

  try testMerging(value);
}

test "multiple dynamic fields" {
  const MultiDynamic = struct {
    a: []const u8,
    b: i32,
    c: []const u8,
  };

  var value = MultiDynamic{
    .a = "hello",
    .b = 12345,
    .c = "world",
  };
  try testMerging(value);

  value.a = "";
  try testMerging(value);
}

test "complex array" {
  const Struct = struct {
    a: u8,
    b: u32,
  };
  const value = [2]Struct{
    .{ .a = 1, .b = 100 },
    .{ .a = 2, .b = 200 },
  };

  try testMerging(value);
}

test "packed struct with mixed alignment fields" {
  const MixedPack = packed struct {
    a: u2,
    b: u8,
    c: u32,
    d: bool,
  };

  const value = MixedPack{
    .a = 3,
    .b = 't',
    .c = 1234567,
    .d = true,
  };

  try testMerging(value);
}

test "struct with zero-sized fields" {
  const ZST_1 = struct {
    a: u32,
    b: void,
    c: [0]u8,
    d: []const u8,
    e: bool,
  };
  try testMerging(ZST_1{
    .a = 123,
    .b = {},
    .c = .{},
    .d = "non-zst",
    .e = false,
  });

  const ZST_2 = struct {
    a: u32,
    zst1: void,
    zst_array: [0]u64,
    dynamic_zst_slice: []const void,
    zst_union: union(enum) {
      z: void,
      d: u64,
    },
    e: bool,
  };

  var value_2 = ZST_2{
    .a = 123,
    .zst1 = {},
    .zst_array = .{},
    .dynamic_zst_slice = &.{ {}, {}, {} },
    .zst_union = .{ .z = {} },
    .e = true,
  };

  try testMerging(value_2);

  value_2.zst_union = .{ .d = 999 };
  try testMerging(value_2);
}

test "array of unions with dynamic fields" {
  const Message = union(enum) {
    text: []const u8,
    code: u32,
    err: void,
  };

  const messages = [3]Message{
    .{ .text = "hello" },
    .{ .code = 404 },
    .{ .text = "world" },
  };

  try testMerging(messages);
}

test "pointer and optional abuse" {
  const Point = struct { x: i32, y: i32 };
  const PointerAbuse = struct {
    a: ?*const Point,
    b: *const ?Point,
    c: ?*const ?Point,
    d: []const ?*const ?Point,
  };

  const p1: Point = .{ .x = 1, .y = 1 };
  const p2: ?Point = .{ .x = 2, .y = 2 };
  const p3: ?Point = null;

  const value = PointerAbuse{
    .a = &p1,
    .b = &p2,
    .c = &p2,
    .d = &.{ &p2, null, &p3 },
  };

  try testMerging(value);
}

test "deeply nested struct with one dynamic field at the end" {
  const Level4 = struct {
    data: []const u8,
  };
  const Level3 = struct {
    l4: Level4,
  };
  const Level2 = struct {
    l3: Level3,
    val: u64,
  };
  const Level1 = struct {
    l2: Level2,
  };

  const value = Level1{
    .l2 = .{
      .l3 = .{
        .l4 = .{
          .data = "we need to go deeper",
        },
      },
      .val = 99,
    },
  };
  try testMerging(value);
}

test "slice of structs with dynamic fields" {
  const LogEntry = struct {
    timestamp: u64,
    message: []const u8,
  };
  const entries = [_]LogEntry{
    .{ .timestamp = 1, .message = "first entry" },
    .{ .timestamp = 2, .message = "" },
    .{ .timestamp = 3, .message = "third entry has a much longer message to test buffer allocation" },
  };

  try testMerging(entries[0..]);
}

test "struct with multiple, non-contiguous dynamic fields" {
  const UserProfile = struct {
    username: []const u8,
    user_id: u64,
    bio: []const u8,
    karma: i32,
    avatar_url: []const u8,
  };

  const user = UserProfile{
    .username = "zigger",
    .user_id = 1234,
    .bio = "Loves comptime and robust software.",
    .karma = 9999,
    .avatar_url = "http://ziglang.org/logo.svg",
  };

  try testMerging(user);
}

test "union with multiple dynamic fields" {
  const Packet = union(enum) {
    message: []const u8,
    points: []const struct { x: f32, y: f32 },
    code: u32,
  };

  try testMerging(Packet{ .message = "hello world" });
  try testMerging(Packet{ .points = &.{.{ .x = 1.0, .y = 2.0 }, .{ .x = 3.0, .y = 4.0}} });
  try testMerging(Packet{ .code = 404 });
}

test "advanced zero-sized type handling" {
  const ZstContainer = struct {
    zst1: void,
    zst2: [0]u8,
    data: []const u8, // This is the only thing that should take space
  };
  try testMerging(ZstContainer{ .zst1 = {}, .zst2 = .{}, .data = "hello" });

  const ZstSliceContainer = struct {
    id: u32,
    zst_slice: []const void,
  };

  try testMerging(ZstSliceContainer{ .id = 99, .zst_slice = &.{ {}, {}, {} } });
}

test "deep optional and pointer nesting" {
  const DeepOptional = struct {
    val: ??*const u32,
  };

  const x: u32 = 123;

  // Fully valued
  try testMerging(DeepOptional{ .val = &x });

  // Inner pointer is null
  try testMerging(DeepOptional{ .val = @as(?*const u32, null) });

  // Outer optional is null
  try testMerging(DeepOptional{ .val = @as(??*const u32, null) });
}

test "recursion limit with dereference" {
  const Node = struct {
    payload: u32,
    next: ?*const @This(),
  };

  const n3 = Node{ .payload = 3, .next = null };
  const n2 = Node{ .payload = 2, .next = &n3 };
  const n1 = Node{ .payload = 1, .next = &n2 };

  // This should only serialize n1 and the pointer to n2. 
  // The `write` for n2 will hit the dereference limit and treat it as a direct (raw pointer) value.
  try testMergingDemerging(n1, .{});
}

test "recursive type merging" {
  const Node = struct {
    payload: u32,
    next: ?*const @This(),
  };

  const n4 = Node{ .payload = 4, .next = null };
  const n3 = Node{ .payload = 3, .next = &n4 };
  const n2 = Node{ .payload = 2, .next = &n3 };
  const n1 = Node{ .payload = 1, .next = &n2 };

  try testMergingDemerging(n1, .{});
}

test "mutual recursion" {
  const Namespace = struct {
    const NodeA = struct {
      name: []const u8,
      b: ?*const NodeB,
    };
    const NodeB = struct {
      value: u32,
      a: ?*const NodeA,
    };
  };

  const NodeA = Namespace.NodeA;
  const NodeB = Namespace.NodeB;

  // Create a linked list: a1 -> b1 -> a2 -> null
  const a2 = NodeA{ .name = "a2", .b = null };
  const b1 = NodeB{ .value = 100, .a = &a2 };
  const a1 = NodeA{ .name = "a1", .b = &b1 };

  try testMergingDemerging(a1, .{});
}

test "deeply nested, mutually recursive structures with no data cycles" {
  const Namespace = struct {
    const MegaStructureA = struct {
      id: u32,
      description: []const u8,
      next: ?*const @This(), // Direct recursion: A -> A
      child_b: *const NodeB, // Mutual recursion: A -> B
    };

    const NodeB = struct {
      value: f64,
      relatives: [2]?*const @This(), // Direct recursion: B -> [2]B
      next_a: ?*const MegaStructureA, // Mutual recursion: B -> A
      leaf: ?*const LeafNode, // Points to a simple terminal node
    };

    const LeafNode = struct {
      data: []const u8,
    };
  };

  const MegaStructureA = Namespace.MegaStructureA;
  const NodeB = Namespace.NodeB;
  const LeafNode = Namespace.LeafNode;

  const leaf1 = LeafNode{ .data = "Leaf Node One" };
  const leaf2 = LeafNode{ .data = "Leaf Node Two" };

  const b_leaf_1 = NodeB{
    .value = 1.1,
    .next_a = null,
    .relatives = .{ null, null },
    .leaf = &leaf1,
  };
  const b_leaf_2 = NodeB{
    .value = 2.2,
    .next_a = null,
    .relatives = .{ null, null },
    .leaf = &leaf2,
  };

  const a_intermediate = MegaStructureA{
    .id = 100,
    .description = "Intermediate A",
    .next = null, // Terminates this A-chain
    .child_b = &b_leaf_1,
  };

  const b_middle = NodeB{
    .value = 3.3,
    .next_a = &a_intermediate,
    .relatives = .{ &b_leaf_1, &b_leaf_2 },
    .leaf = null,
  };

  const a_before_root = MegaStructureA{
    .id = 200,
    .description = "Almost Root A",
    .next = null,
    .child_b = &b_leaf_2,
  };

  const root_node = MegaStructureA{
    .id = 1,
    .description = "The Root",
    .next = &a_before_root,
    .child_b = &b_middle,
  };

  try testMergingDemerging(root_node, .{});
}

const Wrapper = root.Wrapper;

test "Wrapper init, get, and deinit" {
  const Point = struct { x: i32, y: []const u8 };
  var wrapped_point = try Wrapper(Point, .{}).init(&.{ .x = 42, .y = "hello" }, testing.allocator);
  defer wrapped_point.deinit(testing.allocator);

  const p = wrapped_point.get();
  try expectEqual(@as(i32, 42), p.x);
  try std.testing.expectEqualStrings("hello", p.y);
}

test "Wrapper clone" {
  const Data = struct { id: u32, items: []const u32 };
  var wrapped1 = try Wrapper(Data, .{}).init(&.{ .id = 1, .items = &.{ 10, 20, 30 } }, testing.allocator);
  defer wrapped1.deinit(testing.allocator);

  var wrapped2 = try wrapped1.clone(testing.allocator);
  defer wrapped2.deinit(testing.allocator);

  try testing.expect(wrapped1.memory.ptr != wrapped2.memory.ptr);

  const d1 = wrapped1.get();
  const d2 = wrapped2.get();
  try expectEqual(d1.id, d2.id);
  try std.testing.expectEqualSlices(u32, d1.items, d2.items);

  wrapped1.get().id = 99;
  try expectEqual(@as(u32, 99), wrapped1.get().id);
  try expectEqual(@as(u32, 1), wrapped2.get().id);
}

test "Wrapper set" {
  const Data = struct { id: u32, items: []const u32 };
  var wrapped = try Wrapper(Data, .{}).init(&.{ .id = 1, .items = &.{10} }, testing.allocator);
  defer wrapped.deinit(testing.allocator);

  // Set to a larger value
  try wrapped.set(testing.allocator, &.{ .id = 2, .items = &.{ 20, 30, 40 } });
  var d = wrapped.get();
  try expectEqual(@as(u32, 2), d.id);
  try std.testing.expectEqualSlices(u32, &.{ 20, 30, 40 }, d.items);
  
  // Set to a smaller value
  try wrapped.set(testing.allocator, &.{ .id = 3, .items = &.{50} });
  d = wrapped.get();
  try expectEqual(@as(u32, 3), d.id);
  try std.testing.expectEqualSlices(u32, &.{50}, d.items);
}

test "Wrapper repointer" {
  const LogEntry = struct {
    timestamp: u64,
    message: []const u8,
  };

  var wrapped = try Wrapper(LogEntry, .{}).init(&.{ .timestamp = 12345, .message = "initial message" }, testing.allocator);
  defer wrapped.deinit(testing.allocator);

  // Manually move the memory to a new buffer (like reading from a file etc.)
  const new_buffer = try testing.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(@TypeOf(wrapped.memory))), wrapped.memory.len);
  @memcpy(new_buffer, wrapped.memory);
  
  // free the old memory and update the wrapper's memory slice
  testing.allocator.free(wrapped.memory);
  wrapped.memory = new_buffer;

  // internal pointers are now invalid
  wrapped.repointer();

  // Verify that data is correct and pointers are valid
  const entry = wrapped.get();
  try testing.expectEqual(@as(u64, 12345), entry.timestamp);
  try testing.expectEqualStrings("initial message", entry.message);

  // ensure the slice pointer points inside the *new* buffer
  const memory_start = @intFromPtr(wrapped.memory.ptr);
  const memory_end = memory_start + wrapped.memory.len;
  const slice_start = @intFromPtr(entry.message.ptr);
  const slice_end = slice_start + entry.message.len;
  try testing.expect(slice_start >= memory_start and slice_end <= memory_end);
}

test "serialization_functions: unknown pointers as usize" {
  const S = struct { ptr: [*]u8 };
  var dummy: u8 = 0;
  const val = S{ .ptr = @ptrCast(&dummy) };
  
  try testMergingDemerging(val, .{ .serialize_unknown_pointer_as_usize = true });
}

test "serialization_functions: opaque with signature" {
  const MyT = u32;
  const MyMergedOpaque = opaque {
    pub const Underlying = SF.MergedSignature{ .T = MyT, ._align = .@"4" };
    pub const STATIC = true;
    pub fn write(_: *MyT, _: *SF.Dynamic) void {}
    pub fn addDynamicSize(_: *const MyT, _: *usize) void {}
    pub fn repointer(_: *MyT, _: *SF.Dynamic) void {}
  };

  const context = Context.init(MyMergedOpaque, .{}, ToMergedT);
  try testing.expect(context == MyMergedOpaque);
}

test "serialization_functions: alignment sorting in structs" {
  const val = struct {
    a: []const u8,  // align 1
    b: []const u32, // align 4
    c: []const u64, // align 8
  } {
    .a = "1",
    .b = &.{1},
    .c = &.{1},
  };
  
  try testMerging(val);
}

test "serialization_functions: error union with dynamic payload" {
  const MyError = error{Failure};
  const S = struct { data: MyError![]const u8 };
  
  try testMerging(S{ .data = "payload" });
  try testMerging(S{ .data = MyError.Failure });
}

test "meta: Mem utility functions" {
  var buf: [64]u8 align(16) = undefined;
  var mem = SF.Dynamic.init(&buf);

  const sub_mem = mem.from(16);
  try testing.expect(@intFromPtr(sub_mem.ptr) == @intFromPtr(mem.ptr) + 16);

  const unaligned = mem.from(1);
  const realigned = unaligned.alignForward(8);
  try testing.expect(std.mem.isAligned(@intFromPtr(realigned.ptr), 8));
  
  _ = mem.assertAligned(16);

  var out_buf: std.ArrayList(u8) = .empty;
  defer out_buf.deinit(testing.allocator);

  try out_buf.writer(testing.allocator).print("{f}", .{mem});
  try testing.expect(out_buf.items.len > 0);
}

test "meta: Context helpers" {
  const options1 = MergeOptions{ .deslice = false };
  const options2 = MergeOptions{ .deslice = true };
  const ctx = Context{
    .Type = u32,
    .align_hint = null,
    .seen_types = &.{},
    .result_types = &.{},
    .seen_recursive = -1,
    .options = options1,
    .merge_fn = ToMergedT,
  };

  const ctx2 = ctx.reop(options2);
  try testing.expect(ctx2.options.deslice == true);

  const ctx3 = ctx.T(f32);
  try testing.expect(ctx3.Type == f32);
}

test "root: DynamicWrapper and DynamicWrapConverted" {
  const S = struct {
    name: []const u8,
    id: u32,
  };

  const DynWrap = root.DynamicWrapper(S, .{});
  var val = S{ .name = "original", .id = 123 };

  var dw = try DynWrap.init(&val, testing.allocator);
  defer dw.deinit(testing.allocator);

  try testing.expectEqualStrings("original", val.name);
  
  const mem_start = @intFromPtr(dw.memory.ptr);
  const mem_end = mem_start + dw.memory.len;
  try testing.expect(@intFromPtr(val.name.ptr) >= mem_start);
  try testing.expect(@intFromPtr(val.name.ptr) < mem_end);

  var val2 = S{ .name = "new name that is longer", .id = 456 };
  try dw.set(testing.allocator, &val2);
  try testing.expectEqualStrings("new name that is longer", val2.name);

  const val3, var dw2 = try dw.clone(&val2, testing.allocator);
  defer dw2.deinit(testing.allocator);
  try testing.expectEqualStrings("new name that is longer", val3.name);
}

test "root: DynamicWrapper returns null for static types" {
  const StaticS = struct { a: u32, b: i32 };
  const res = root.DynamicWrapper(StaticS, .{});
  try testing.expect(res == void);
}

test "serialization_functions: alignForward underflow catch" {
  var buf: [4]u8 align(4) = undefined;
  const mem = SF.Dynamic.init(&buf);
  const offset = mem.from(2);
  _ = offset.alignForward(4); 
}

test "serialization_functions: nested deslicing false" {
  const S = struct { data: []const u8 };
  const val = S{ .data = "test" };
  const MergedT = Context.init(S, .{ .deslice = false }, ToMergedT);
  var size: usize = 0;
  MergedT.addDynamicSize(&val, &size);
  try testing.expect(size == 0);
}

test "serialization_functions: depointer false" {
  const x: u32 = 42;
  const ptr: *const u32 = &x;
  const MergedT = Context.init(*const u32, .{ .depointer = false }, ToMergedT);
  var size: usize = 0;
  MergedT.addDynamicSize(&ptr, &size);
  try testing.expect(size == 0);
}

test "serialization_functions: nested error unions and optionals" {
  const Payload = error{Fail}!?[]const u8;
  const S = struct { p: Payload };

  try testMerging(S{ .p = @as([]const u8, "nest") });
  try testMerging(S{ .p = @as(?[]const u8, null) });
  try testMerging(S{ .p = error.Fail });
}

test "serialization_functions: multi-level pointers (**T)" {
  const val: u32 = 42;
  const p1: *const u32 = &val;
  const p2: *const *const u32 = &p1;

  // recursive GetPointerMergedT
  try testMergingDemerging(p2, .{ .depointer = true });
}

test "serialization_functions: union with mixed static and dynamic fields" {
  const MixedUnion = union(enum) {
    static: u64,
    dynamic: []const u8,
    nested_dynamic: struct { a: []const u32 },
  };

  try testMerging(MixedUnion{ .static = 12345 });
  try testMerging(MixedUnion{ .dynamic = "hello union" });
  try testMerging(MixedUnion{ .nested_dynamic = .{ .a = &.{ 1, 2, 3 } } });
}

test "serialization_functions: zero-sized array of dynamic types" {
  const S = struct {
    items: [0]struct { s: []const u8 },
  };
  // Should be treated as STATIC
  try testMerging(S{ .items = .{} });
}

test "serialization_functions: alignment stress test" {
  // A struct that forces padding between dynamic segments
  const StrictAlign = struct {
    // align(1)
    a: []const u8, 
    // align(16) - forces alignForward to jump significantly
    b: []const align(16) u32, 
    c: u8,
  };

  const val = StrictAlign{
    .a = "bit",
    .b = comptime blk: {
      const retval: [2]u32 align(16) = .{ 0xDEADBEEF, 0xCAFEBABE };
      break :blk retval[0..];
    },
    .c = 1,
  };

  try testMerging(val);
}

test "serialization_functions: alignment stress test 2" {
  // A struct that forces padding between dynamic segments
  const StrictAlign = struct {
    // align(1)
    a: []const u8, 
    // align(16) - forces alignForward to jump significantly
    b: []const align(16) u32, 
    c: u8,
  };

  const val = StrictAlign{
    .a = "bit_by_bitset",
    .b = comptime blk: {
      const retval: [6]u32 align(16) = .{ 0xDEADBEEF, 0xCAFEBABE, 0xB00BF00D, 0xDEADBEEF, 0xCAFEBABE, 0xB00BF00D };
      break :blk retval[0..];
    },
    .c = 1,
  };

  try testMerging(val);
}

test "meta: NonConstPointer with different sizes" {
  const T = []const u8;
  const One = meta.NonConstPointer(T, .one);
  const Slice = meta.NonConstPointer(T, .slice);
  
  try testing.expect(@typeInfo(One).pointer.size == .one);
  try testing.expect(@typeInfo(Slice).pointer.size == .slice);
  try testing.expect(@typeInfo(One).pointer.is_const == false);
}

test "root: Wrapper.set with exact same size (remap path)" {
  const S = struct { a: []const u8 };
  var wrapped = try Wrapper(S, .{}).init(&.{ .a = "old" }, testing.allocator);
  defer wrapped.deinit(testing.allocator);

  try wrapped.set(testing.allocator, &.{ .a = "new" });
  try testing.expectEqualSlices(u8, "new", wrapped.get().a);
}

test "serialization_functions: vector types" {
  const v: @Vector(4, f32) = .{ 1.1, 2.2, 3.3, 4.4 };
  try testMerging(v);
}

test "serialization_functions: recursive structs with multiple paths" {
  const Node = struct {
    child_a: ?*const @This(),
    child_b: ?*const @This(),
    data: u32,
  };

  const leaf = Node{ .child_a = null, .child_b = null, .data = 100 };
  const root_node = Node{
    .child_a = &leaf,
    .child_b = &leaf,
    .data = 200,
  };

  try testMerging(root_node);
}

test "serialization_functions: context reop and realign" {
  const options = MergeOptions{ .deslice = false };
  const ctx = Context {
    .Type = u32,
    .align_hint = null,
    .seen_types = &.{},
    .result_types = &.{},
    .options = options,
    .seen_recursive = -1,
    .merge_fn = ToMergedT,
  };

  const ctx_new = ctx.reop(.{ .deslice = true });
  try testing.expect(ctx.options.deslice == false);
  try testing.expect(ctx_new.options.deslice == true);
}
