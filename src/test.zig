const std = @import("std");
const one = @import("root.zig");
const testing = std.testing;

fn expectEquivalent(expected: anytype, actual: anytype) anyerror!void {
    const T = @TypeOf(expected);
    if (T != @TypeOf(actual)) return error.TestExpectedEqual;

    switch (@typeInfo(T)) {
        .noreturn, .@"opaque", .frame, .@"anyframe" => @compileError("Unsupported type in expectEquivalent: " ++ @typeName(T)),
        .void => return,
        .type => try testing.expect(expected == actual),
        .bool, .int, .float, .comptime_float, .comptime_int, .enum_literal, .@"enum", .@"fn", .error_set => {
            try testing.expect(expected == actual);
        },
        .pointer => |pointer| switch (pointer.size) {
            .one, .c => try expectEquivalent(expected.*, actual.*),
            .many => try testing.expect(expected == actual),
            .slice => {
                try testing.expectEqual(expected.len, actual.len);
                for (expected, actual) |ev, av| {
                    try expectEquivalent(ev, av);
                }
            },
        },
        .array => |array| {
            inline for (0..array.len) |i| {
                try expectEquivalent(expected[i], actual[i]);
            }
        },
        .vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                try testing.expect(std.meta.eql(expected[i], actual[i]));
            }
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                try expectEquivalent(@field(expected, field.name), @field(actual, field.name));
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type == null) @compileError("Cannot compare untagged union: " ++ @typeName(T));
            const Tag = std.meta.Tag(T);
            try expectEquivalent(@as(Tag, expected), @as(Tag, actual));
            switch (expected) {
                inline else => |payload, tag| try expectEquivalent(payload, @field(actual, @tagName(tag))),
            }
        },
        .optional => {
            if (expected) |ep| {
                if (actual) |ap| {
                    try expectEquivalent(ep, ap);
                } else {
                    return error.TestExpectedEqual;
                }
            } else {
                try testing.expect(actual == null);
            }
        },
        .error_union => {
            if (expected) |ep| {
                if (actual) |ap| {
                    try expectEquivalent(ep, ap);
                } else |_| {
                    return error.TestExpectedEqual;
                }
            } else |ee| {
                if (actual) |_| {
                    return error.TestExpectedEqual;
                } else |ae| {
                    try expectEquivalent(ee, ae);
                }
            }
        },
        else => @compileError("Unsupported type in expectEquivalent: " ++ @typeName(T)),
    }
}

fn needsFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one, .slice => true,
            .many, .c => false,
        },
        .array => |ai| needsFree(ai.child),
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (needsFree(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |oi| needsFree(oi.child),
        .error_union => |ei| needsFree(ei.payload),
        .@"union" => |ui| blk: {
            inline for (ui.fields) |field| {
                if (needsFree(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn freeOwned(comptime T: type, gpa: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one => {
                freeOwned(pi.child, gpa, @constCast(value.*));
                gpa.destroy(@constCast(value.*));
            },
            .slice => {
                if (needsFree(pi.child) and @sizeOf(pi.child) > 0) {
                    for (value.*) |elem| {
                        var item = elem;
                        freeOwned(pi.child, gpa, &item);
                    }
                }
                gpa.free(@constCast(value.*));
            },
            .many, .c => {},
        },
        .array => |ai| {
            if (needsFree(ai.child)) {
                inline for (0..ai.len) |i| {
                    var item = value.*[i];
                    freeOwned(ai.child, gpa, &item);
                }
            }
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                if (needsFree(field.type)) {
                    var field_copy = @field(value.*, field.name);
                    freeOwned(field.type, gpa, &field_copy);
                }
            }
        },
        .optional => |oi| {
            if (value.*) |*payload| freeOwned(oi.child, gpa, @constCast(payload));
        },
        .error_union => |ei| {
            if (value.*) |*payload| freeOwned(ei.payload, gpa, @constCast(payload)) else |_| {}
        },
        .@"union" => {
            switch (value.*) {
                inline else => |*payload| freeOwned(@TypeOf(payload.*), gpa, @constCast(payload)),
            }
        },
        else => {},
    }
}

fn testRoundtrip(_value: anytype) !void {
    var value = _value;
    const T = @TypeOf(value);

    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const expected_alignment = one.Converter(T, .{}).alignment.toByteUnits();
    try testing.expect(std.mem.isAligned(@intFromPtr(bytes.ptr), expected_alignment));

    const untrusted = one.Untrusted(T, .{}).init(bytes);
    const trusted = try untrusted.validate();
    const unsafe_trusted = untrusted.unsafeTrusted();

    const out_untrusted = try untrusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_untrusted));
    try expectEquivalent(value, out_untrusted);

    const out_trusted = try trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_trusted));
    try expectEquivalent(value, out_trusted);

    const out_unsafe = try unsafe_trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_unsafe));
    try expectEquivalent(value, out_unsafe);

    var wrapped = try one.Wrapper(T, .{}).init(&value, testing.allocator);
    defer wrapped.deinit(testing.allocator);
    try testing.expect(std.mem.isAligned(@intFromPtr(wrapped.memory.ptr), expected_alignment));

    const wrapped_trusted = try wrapped.untrusted().validate();
    const out_wrapped = try wrapped_trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_wrapped));
    try expectEquivalent(value, out_wrapped);
}

test "primitives" {
    try testRoundtrip(@as(u32, 42));
    try testRoundtrip(@as(f64, 123.456));
    try testRoundtrip(@as(bool, true));
    try testRoundtrip(@as(void, {}));
}

test "pointers" {
    var x: u64 = 12345;
    try testRoundtrip(@as(*const u64, &x));

    const p1: *const u64 = &x;
    const p2: *const *const u64 = &p1;
    try testRoundtrip(p2);
}

test "slices" {
    try testRoundtrip(@as([]const u8, "hello zig"));

    const Point = struct { x: u8, y: u8 };
    try testRoundtrip(@as([]const Point, &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } }));

    try testRoundtrip(@as([]const []const u8, &.{ "hello", "world", "zig", "rocks" }));
    try testRoundtrip(@as([]const u8, &.{}));
    try testRoundtrip(@as([]const []const u8, &.{}));
    try testRoundtrip(@as([]const []const u8, &.{ "", "a", "" }));
}

test "arrays" {
    try testRoundtrip([4]u8{ 1, 2, 3, 4 });

    const Point = struct { x: u8, y: u8 };
    try testRoundtrip([2]Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } });
    try testRoundtrip([2][2]u8{ .{ 1, 2 }, .{ 3, 4 } });
    try testRoundtrip([0]u8{});
}

test "structs and enums" {
    const Point = struct { x: i32, y: i32 };
    const Line = struct { p1: Point, p2: Point };
    const Color = enum { red, green, blue };

    try testRoundtrip(Point{ .x = -10, .y = 20 });
    try testRoundtrip(Line{ .p1 = .{ .x = 1, .y = 2 }, .p2 = .{ .x = 3, .y = 4 } });
    try testRoundtrip(Color.green);
}

test "optional and error unions" {
    const MyError = error{Oops};
    const Wrapped = struct { v: MyError!u32 };

    try testRoundtrip(@as(?i32, 42));
    try testRoundtrip(@as(?i32, null));

    var y: i32 = 123;
    try testRoundtrip(@as(?*const i32, &y));
    try testRoundtrip(@as(?*const i32, null));

    try testRoundtrip(Wrapped{ .v = 123 });
    try testRoundtrip(Wrapped{ .v = MyError.Oops });
}

test "tagged unions" {
    const Payload = union(enum) {
        a: u32,
        b: bool,
        c: void,
    };

    try testRoundtrip(Payload{ .a = 99 });
    try testRoundtrip(Payload{ .b = false });
    try testRoundtrip(Payload{ .c = {} });
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

    const i: i32 = 42;
    var value = KitchenSink{
        .a = -1,
        .b = "dynamic slice",
        .c = .{ .{ .c = 1, .d = true }, .{ .c = 2, .d = false } },
        .d = &i,
        .e = 3.14,
    };

    try testRoundtrip(value);

    value.b = "";
    try testRoundtrip(value);

    value.d = null;
    try testRoundtrip(value);
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

    try testRoundtrip(items[0..]);
}

test "complex composition" {
    const Complex1 = struct { a: u32, b: u32, c: u32 };
    const Complex2 = struct { a: Complex1, b: []const Complex1 };
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

    try testRoundtrip(value);
}

test "multiple dynamic fields and non contiguous layout" {
    const UserProfile = struct {
        username: []const u8,
        user_id: u64,
        bio: []const u8,
        karma: i32,
        avatar_url: []const u8,
    };

    try testRoundtrip(UserProfile{
        .username = "zigger",
        .user_id = 1234,
        .bio = "Loves comptime and robust software.",
        .karma = 9999,
        .avatar_url = "http://ziglang.org/logo.svg",
    });
}

test "packed struct with mixed alignment fields" {
    const MixedPack = packed struct {
        a: u2,
        b: u8,
        c: u32,
        d: bool,
    };

    try testRoundtrip(MixedPack{ .a = 3, .b = 't', .c = 1234567, .d = true });
}

test "zero-sized and void-heavy types" {
    const ZST1 = struct {
        a: u32,
        b: void,
        c: [0]u8,
        d: []const u8,
        e: bool,
    };

    try testRoundtrip(ZST1{ .a = 123, .b = {}, .c = .{}, .d = "non-zst", .e = false });

    const ZST2 = struct {
        a: u32,
        zst1: void,
        zst_array: [0]u64,
        dynamic_zst_slice: []const void,
        zst_union: union(enum) { z: void, d: u64 },
        e: bool,
    };

    try testRoundtrip(ZST2{
        .a = 123,
        .zst1 = {},
        .zst_array = .{},
        .dynamic_zst_slice = &.{ {}, {}, {} },
        .zst_union = .{ .z = {} },
        .e = true,
    });

    try testRoundtrip(ZST2{
        .a = 123,
        .zst1 = {},
        .zst_array = .{},
        .dynamic_zst_slice = &.{ {}, {}, {} },
        .zst_union = .{ .d = 999 },
        .e = true,
    });
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

    try testRoundtrip(messages);
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

    try testRoundtrip(value);
}

test "deeply nested with late dynamic field" {
    const Level4 = struct { data: []const u8 };
    const Level3 = struct { l4: Level4 };
    const Level2 = struct { l3: Level3, val: u64 };
    const Level1 = struct { l2: Level2 };

    try testRoundtrip(Level1{
        .l2 = .{
            .l3 = .{ .l4 = .{ .data = "we need to go deeper" } },
            .val = 99,
        },
    });
}

test "union with multiple dynamic fields" {
    const Packet = union(enum) {
        message: []const u8,
        points: []const struct { x: f32, y: f32 },
        code: u32,
    };

    try testRoundtrip(Packet{ .message = "hello world" });
    try testRoundtrip(Packet{ .points = &.{ .{ .x = 1.0, .y = 2.0 }, .{ .x = 3.0, .y = 4.0 } } });
    try testRoundtrip(Packet{ .code = 404 });
}

test "deep optional and pointer nesting" {
    const DeepOptional = struct { val: ??*const u32 };
    const x: u32 = 123;

    try testRoundtrip(DeepOptional{ .val = &x });
    try testRoundtrip(DeepOptional{ .val = @as(?*const u32, null) });
    try testRoundtrip(DeepOptional{ .val = @as(??*const u32, null) });
}

test "recursive linked list" {
    const Node = struct {
        payload: u32,
        next: ?*const @This(),
    };

    const n4 = Node{ .payload = 4, .next = null };
    const n3 = Node{ .payload = 3, .next = &n4 };
    const n2 = Node{ .payload = 2, .next = &n3 };
    const n1 = Node{ .payload = 1, .next = &n2 };

    try testRoundtrip(n1);
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

    const a2 = NodeA{ .name = "a2", .b = null };
    const b1 = NodeB{ .value = 100, .a = &a2 };
    const a1 = NodeA{ .name = "a1", .b = &b1 };

    try testRoundtrip(a1);
}

test "deeply nested mutual recursion without cycles" {
    const Namespace = struct {
        const MegaA = struct {
            id: u32,
            description: []const u8,
            next: ?*const @This(),
            child_b: *const NodeB,
        };

        const NodeB = struct {
            value: f64,
            relatives: [2]?*const @This(),
            next_a: ?*const MegaA,
            leaf: ?*const Leaf,
        };

        const Leaf = struct {
            data: []const u8,
        };
    };

    const MegaA = Namespace.MegaA;
    const NodeB = Namespace.NodeB;
    const Leaf = Namespace.Leaf;

    const leaf1 = Leaf{ .data = "Leaf Node One" };
    const leaf2 = Leaf{ .data = "Leaf Node Two" };

    const b_leaf_1 = NodeB{ .value = 1.1, .next_a = null, .relatives = .{ null, null }, .leaf = &leaf1 };
    const b_leaf_2 = NodeB{ .value = 2.2, .next_a = null, .relatives = .{ null, null }, .leaf = &leaf2 };

    const a_intermediate = MegaA{ .id = 100, .description = "Intermediate A", .next = null, .child_b = &b_leaf_1 };
    const b_middle = NodeB{ .value = 3.3, .next_a = &a_intermediate, .relatives = .{ &b_leaf_1, &b_leaf_2 }, .leaf = null };
    const a_before_root = MegaA{ .id = 200, .description = "Almost Root A", .next = null, .child_b = &b_leaf_2 };
    const root_node = MegaA{ .id = 1, .description = "The Root", .next = &a_before_root, .child_b = &b_middle };

    try testRoundtrip(root_node);
}

test "mutual recursion with complex mixed layout (acyclic data)" {
    const Namespace = struct {
        const Stage = enum { cold, warm, hot };
        const Kind = enum { leaf, branch };

        const NodeA = struct {
            id: u32,
            stage: Stage,
            label: []const u8,
            links: [2]?*const NodeB,
            meta: union(enum) {
                none: void,
                codes: [3]u16,
                tags: []const []const u8,
            },
            status: error{Bad}![]const u8,
        };

        const NodeB = struct {
            kind: Kind,
            weights: []const f32,
            back: ?*const NodeA,
            children: []const ?*const NodeA,
            payload: union(enum) {
                n: i64,
                bytes: []const u8,
                flags: [4]bool,
            },
        };
    };

    const NodeA = Namespace.NodeA;
    const NodeB = Namespace.NodeB;

    const a3 = NodeA{
        .id = 3,
        .stage = .hot,
        .label = "a3",
        .links = .{ null, null },
        .meta = .{ .codes = .{ 1, 2, 3 } },
        .status = "ok-a3",
    };

    const b2 = NodeB{
        .kind = .leaf,
        .weights = &.{ 0.5, 0.75 },
        .back = &a3,
        .children = &.{ null },
        .payload = .{ .flags = .{ true, false, true, false } },
    };

    const a2 = NodeA{
        .id = 2,
        .stage = .warm,
        .label = "a2",
        .links = .{ null, &b2 },
        .meta = .{ .tags = &.{ "k1", "k2" } },
        .status = error.Bad,
    };

    const b1 = NodeB{
        .kind = .branch,
        .weights = &.{ 1.0, 2.0, 4.0 },
        .back = &a2,
        .children = &.{ &a2, &a3, null },
        .payload = .{ .bytes = "b1-payload" },
    };

    const a1 = NodeA{
        .id = 1,
        .stage = .cold,
        .label = "a1-root",
        .links = .{ &b1, null },
        .meta = .{ .none = {} },
        .status = "ok-a1",
    };

    try testRoundtrip(a1);
}

test "multi-level mutual recursion with unions slices arrays pointers enums (acyclic data)" {
    const Namespace = struct {
        const Mode = enum { stable, degraded, emergency };
        const BranchKind = enum { ingest, process, emit };
        const ChunkTag = enum { alpha, beta, gamma };

        const Root = struct {
            mode: Mode,
            title: []const u8,
            branch: *const Branch,
            history: [2]?*const Branch,
            annotations: []const union(enum) {
                text: []const u8,
                marker: u32,
                empty: void,
            },
        };

        const Branch = struct {
            kind: BranchKind,
            parent: ?*const Root,
            leaves: []const *const Leaf,
            chooser: union(enum) {
                primary: *const Leaf,
                alt: ?*const Leaf,
                packed: [2]u8,
            },
            health: error{Offline}![]const u8,
        };

        const Leaf = struct {
            idx: u16,
            attrs: [3]u8,
            next: ?*const Leaf,
            owner: ?*const Branch,
            chunks: []const Chunk,
        };

        const Chunk = struct {
            tag: ChunkTag,
            data: []const u8,
            root_ref: ?*const Root,
        };
    };

    const Root = Namespace.Root;
    const Branch = Namespace.Branch;
    const Leaf = Namespace.Leaf;
    const Chunk = Namespace.Chunk;

    const c1 = Chunk{ .tag = .alpha, .data = "c1", .root_ref = null };
    const c2 = Chunk{ .tag = .beta, .data = "chunk-two", .root_ref = null };
    const c3 = Chunk{ .tag = .gamma, .data = "", .root_ref = null };

    const leaf3 = Leaf{
        .idx = 3,
        .attrs = .{ 9, 9, 9 },
        .next = null,
        .owner = null,
        .chunks = &.{ c3 },
    };

    const leaf2 = Leaf{
        .idx = 2,
        .attrs = .{ 4, 5, 6 },
        .next = &leaf3,
        .owner = null,
        .chunks = &.{ c2 },
    };

    const leaf1 = Leaf{
        .idx = 1,
        .attrs = .{ 1, 2, 3 },
        .next = &leaf2,
        .owner = null,
        .chunks = &.{ c1, c2 },
    };

    const branch2 = Branch{
        .kind = .emit,
        .parent = null,
        .leaves = &.{ &leaf3 },
        .chooser = .{ .primary = &leaf3 },
        .health = error.Offline,
    };

    const branch1 = Branch{
        .kind = .process,
        .parent = null,
        .leaves = &.{ &leaf1, &leaf2, &leaf3 },
        .chooser = .{ .alt = &leaf2 },
        .health = "healthy",
    };

    const root2 = Root{
        .mode = .degraded,
        .title = "root-2",
        .branch = &branch2,
        .history = .{ null, null },
        .annotations = &.{ .{ .marker = 2 }, .{ .text = "backup" } },
    };

    const root1 = Root{
        .mode = .stable,
        .title = "root-1",
        .branch = &branch1,
        .history = .{ &branch2, null },
        .annotations = &.{ .{ .text = "primary" }, .{ .empty = {} }, .{ .marker = 42 } },
    };

    _ = root2; // keep second root alive for pointer shape variations in this test scope
    try testRoundtrip(root1);
}

test "nested error unions and optionals" {
    const Payload = error{Fail}!?[]const u8;
    const S = struct { p: Payload };

    try testRoundtrip(S{ .p = @as([]const u8, "nest") });
    try testRoundtrip(S{ .p = @as(?[]const u8, null) });
    try testRoundtrip(S{ .p = error.Fail });
}

test "union with mixed static and dynamic fields" {
    const MixedUnion = union(enum) {
        static: u64,
        dynamic: []const u8,
        nested_dynamic: struct { a: []const u32 },
    };

    try testRoundtrip(MixedUnion{ .static = 12345 });
    try testRoundtrip(MixedUnion{ .dynamic = "hello union" });
    try testRoundtrip(MixedUnion{ .nested_dynamic = .{ .a = &.{ 1, 2, 3 } } });
}

test "zero-sized array of dynamic types" {
    const S = struct {
        items: [0]struct { s: []const u8 },
    };
    try testRoundtrip(S{ .items = .{} });
}

test "alignment stress tests" {
    const StrictAlign = struct {
        a: []const u8,
        b: []align(16) const u32,
        c: u8,
    };

    const v1 = StrictAlign{
        .a = "bit",
        .b = comptime blk: {
            const retval: [2]u32 align(16) = .{ 0xDEADBEEF, 0xCAFEBABE };
            break :blk retval[0..];
        },
        .c = 1,
    };

    const v2 = StrictAlign{
        .a = "bit_by_bitset",
        .b = comptime blk: {
            const retval: [6]u32 align(16) = .{ 0xDEADBEEF, 0xCAFEBABE, 0xB00BF00D, 0xDEADBEEF, 0xCAFEBABE, 0xB00BF00D };
            break :blk retval[0..];
        },
        .c = 1,
    };

    try testRoundtrip(v1);
    try testRoundtrip(v2);

    const expected = one.Converter(StrictAlign, .{}).alignment.toByteUnits();
    try testing.expectEqual(@as(usize, 16), expected);
}

test "vector types" {
    const v: @Vector(4, f32) = .{ 1.1, 2.2, 3.3, 4.4 };
    try testRoundtrip(v);
}

test "recursive struct with multiple paths" {
    const Node = struct {
        child_a: ?*const @This(),
        child_b: ?*const @This(),
        data: u32,
    };

    const leaf = Node{ .child_a = null, .child_b = null, .data = 100 };
    const root_node = Node{ .child_a = &leaf, .child_b = &leaf, .data = 200 };

    try testRoundtrip(root_node);
}

test "validate distinguishes too many vs too few bytes" {
    const T = struct { a: []const u8 };
    const value = T{ .a = "hello" };
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const short = bytes[0 .. bytes.len - 1];
    try testing.expectError(error.NotEnoughBytes, one.Untrusted(T, .{}).init(short).validate());

    var long = try testing.allocator.alignedAlloc(u8, one.Converter(T, .{}).alignment, bytes.len + 1);
    defer testing.allocator.free(long);
    @memcpy(long[0..bytes.len], bytes);
    long[bytes.len] = 0;
    try testing.expectError(error.TooManyBytes, one.Untrusted(T, .{}).init(long).validate());
}

test "untrusted checked access reports OutOfBounds" {
    const T = struct { a: []const u8 };
    const value = T{ .a = "abc" };
    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const short = bytes[0 .. bytes.len - 1];
    const u = one.Untrusted(T, .{}).init(short);

    const a = try u.field("a");
    const elem = try a.at(2);
    try testing.expectError(error.OutOfBounds, elem.value());
    try testing.expectError(error.OutOfBounds, a.at(10));
}

test "accessor chaining and dynamic get" {
    const T = struct {
        user: struct {
            id: u32,
            name: []const u8,
        },
        tags: []const []const u8,
    };

    const value = T{
        .user = .{ .id = 7, .name = "bob" },
        .tags = &.{ "a", "bb", "ccc" },
    };

    const bytes = try one.serializeAlloc(T, .{}, &value, testing.allocator);
    defer testing.allocator.free(bytes);

    const u = one.Untrusted(T, .{}).init(bytes);
    const user = try u.field("user");
    const id = try user.field("id");
    try testing.expectEqual(@as(u32, 7), try id.value());

    const name = try user.field("name");
    const name_checked = try name.get();
    try testing.expectEqual(@as(usize, 3), try name_checked.len());

    const tags = try u.field("tags");
    const tags_checked = try tags.get();
    const second = try tags_checked.at(1);
    const second_checked = try second.get();
    const ch = try second_checked.at(1);
    try testing.expectEqual(@as(u8, 'b'), try ch.value());
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
