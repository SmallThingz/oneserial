const std = @import("std");
const one = @import("root.zig");
const testing = std.testing;

fn freeOwned(comptime T: type, gpa: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one => {
                freeOwned(pi.child, gpa, @constCast(value.*));
                gpa.destroy(@constCast(value.*));
            },
            .slice => {
                for (value.*) |*elem| {
                    freeOwned(pi.child, gpa, @constCast(elem));
                }
                gpa.free(@constCast(value.*));
            },
            .many, .c => {},
        },
        .array => |ai| {
            inline for (0..ai.len) |i| {
                freeOwned(ai.child, gpa, @constCast(&value.*[i]));
            }
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                freeOwned(field.type, gpa, @constCast(&@field(value.*, field.name)));
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

test "basic roundtrip and trust flow" {
    const T = struct {
        id: u32,
        active: bool,
        rating: f32,
    };

    const v = T{ .id = 42, .active = true, .rating = 8.5 };
    const bytes = try one.serializeAlloc(T, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);

    const untrusted = one.Untrusted(T, .{}).init(bytes);
    const trusted = try untrusted.validate();

    const out = try trusted.toOwned(testing.allocator);
    try testing.expectEqualDeep(v, out);
}

test "slice is len-header plus payload (no pointer bytes)" {
    const T = struct { data: []const u8 };
    const v = T{ .data = "abc" };

    const bytes = try one.serializeAlloc(T, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, @sizeOf(one.Size) + v.data.len), bytes.len);

    const view = one.Untrusted(T, .{}).init(bytes);
    const data = try view.field("data");
    try testing.expectEqual(@as(usize, 3), try data.len());
    const ch = try data.at(1);
    try testing.expectEqual(@as(u8, 'b'), try ch.value());
}

test "pointer one stores payload only and reconstructs pointer" {
    const T = struct { p: *const u32 };
    var x: u32 = 1234;
    const v = T{ .p = &x };

    const bytes = try one.serializeAlloc(T, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, @sizeOf(u32)), bytes.len);

    const untrusted = one.Untrusted(T, .{}).init(bytes);
    const out = try untrusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out));

    try testing.expectEqual(@as(u32, 1234), out.p.*);
}

test "validate distinguishes too many vs too few bytes" {
    const T = struct { a: []const u8 };
    const v = T{ .a = "hello" };

    const bytes = try one.serializeAlloc(T, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);

    const short = bytes[0 .. bytes.len - 1];
    try testing.expectError(error.NotEnoughBytes, one.Untrusted(T, .{}).init(short).validate());

    var long = try testing.allocator.alloc(u8, bytes.len + 1);
    defer testing.allocator.free(long);
    @memcpy(long[0..bytes.len], bytes);
    long[bytes.len] = 0;
    try testing.expectError(error.TooManyBytes, one.Untrusted(T, .{}).init(long).validate());
}

test "untrusted checked access reports OutOfBounds" {
    const T = struct { a: []const u8 };
    const v = T{ .a = "abc" };

    const bytes = try one.serializeAlloc(T, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);

    const short = bytes[0 .. bytes.len - 1];
    const u = one.Untrusted(T, .{}).init(short);

    const a = try u.field("a");
    const elem = try a.at(2);
    try testing.expectError(error.OutOfBounds, elem.value());
    try testing.expectError(error.OutOfBounds, a.at(10));
}

test "trusted and unsafe trusted paths" {
    const T = struct { msg: []const u8, n: u16 };
    const v = T{ .msg = "zig", .n = 9 };

    var wrapper = try one.Wrapper(T, .{}).init(&v, testing.allocator);
    defer wrapper.deinit(testing.allocator);

    const untrusted = wrapper.untrusted();
    const trusted = try untrusted.validate();
    const unsafe_trusted = untrusted.unsafeTrusted();

    const out1 = try trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out1));
    const out2 = try unsafe_trusted.toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out2));

    try testing.expectEqualDeep(v.n, out1.n);
    try testing.expectEqualDeep(v.n, out2.n);
    try testing.expectEqualStrings(v.msg, out1.msg);
    try testing.expectEqualStrings(v.msg, out2.msg);
}

test "nested accessor chaining with dynamic get" {
    const T = struct {
        user: struct {
            id: u32,
            name: []const u8,
        },
        tags: []const []const u8,
    };

    const v = T{
        .user = .{ .id = 7, .name = "bob" },
        .tags = &.{ "a", "bb", "ccc" },
    };

    const bytes = try one.serializeAlloc(T, .{}, &v, testing.allocator);
    defer testing.allocator.free(bytes);

    const u = one.Untrusted(T, .{}).init(bytes);

    const user = try u.field("user");
    const name = try user.field("name");
    const name_checked = try name.get();
    try testing.expectEqual(@as(usize, 3), try name_checked.len());

    const tags = try u.field("tags");
    const tags_checked = try tags.get();
    const first_tag = try tags_checked.at(0);
    const first_tag_checked = try first_tag.get();
    const ch0 = try first_tag_checked.at(0);
    try testing.expectEqual(@as(u8, 'a'), try ch0.value());
}

test "toOwned reconstructs recursive acyclic structure" {
    const Node = struct {
        value: u32,
        next: ?*const @This(),
    };

    const n3 = Node{ .value = 3, .next = null };
    const n2 = Node{ .value = 2, .next = &n3 };
    const n1 = Node{ .value = 1, .next = &n2 };

    const bytes = try one.serializeAlloc(Node, .{}, &n1, testing.allocator);
    defer testing.allocator.free(bytes);

    const out = try one.Untrusted(Node, .{}).init(bytes).toOwned(testing.allocator);
    defer freeOwned(Node, testing.allocator, @constCast(&out));

    try testing.expectEqual(@as(u32, 1), out.value);
    try testing.expect(out.next != null);
    try testing.expectEqual(@as(u32, 2), out.next.?.*.value);
    try testing.expect(out.next.?.*.next != null);
    try testing.expectEqual(@as(u32, 3), out.next.?.*.next.?.*.value);
}

test "tagged union and error union roundtrip" {
    const EU = error{Bad};
    const Payload = union(enum) {
        code: u32,
        text: []const u8,
    };

    const T = struct {
        payload: Payload,
        maybe: EU![]const u8,
    };

    const v_ok = T{
        .payload = .{ .text = "ok" },
        .maybe = "value",
    };

    const bytes_ok = try one.serializeAlloc(T, .{}, &v_ok, testing.allocator);
    defer testing.allocator.free(bytes_ok);

    const out_ok = try one.Untrusted(T, .{}).init(bytes_ok).toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_ok));

    switch (out_ok.payload) {
        .text => |s| try testing.expectEqualStrings("ok", s),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("value", try out_ok.maybe);

    const v_err = T{
        .payload = .{ .code = 404 },
        .maybe = EU.Bad,
    };

    const bytes_err = try one.serializeAlloc(T, .{}, &v_err, testing.allocator);
    defer testing.allocator.free(bytes_err);

    const out_err = try one.Untrusted(T, .{}).init(bytes_err).toOwned(testing.allocator);
    defer freeOwned(T, testing.allocator, @constCast(&out_err));

    switch (out_err.payload) {
        .code => |c| try testing.expectEqual(@as(u32, 404), c),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectError(EU.Bad, out_err.maybe);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
