const std = @import("std");
const meta = @import("meta.zig");
const root = @import("root.zig");

pub const ValidationError = error{
    NotEnoughBytes,
    /// Returned when object parsing succeeded but trailing bytes remain.
    /// Callers that frame multiple objects may intentionally ignore this.
    TooManyBytes,
    LengthOverflow,
    InvalidTag,
    InvalidEnumTag,
    InvalidUnionTag,
    OutOfBounds,
};

pub const SerializeError = ValidationError || error{ OutOfMemory, NoSpaceLeft };
pub const DeserializeError = ValidationError || error{OutOfMemory};

/// Tag-level support. Some tags (pointer/union) require additional shape checks;
/// use `supportsType` for full type-level validation.
pub fn supportsTypeId(tag: std.builtin.TypeId) bool {
    return switch (tag) {
        .void,
        .bool,
        .int,
        .float,
        .vector,
        .@"enum",
        .array,
        .pointer,
        .@"struct",
        .optional,
        .error_union,
        .@"union",
        .null,
        => true,
        else => false,
    };
}

fn seenType(comptime seen: []const type, comptime T: type) bool {
    inline for (seen) |s| if (s == T) return true;
    return false;
}

fn supportsTypeInner(comptime T: type, comptime seen: []const type) bool {
    @setEvalBranchQuota(1_000_000);
    if (seenType(seen, T)) return true;
    const next_seen = seen ++ [1]type{T};

    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .vector, .null => true,
        .@"enum" => true,
        .array => |ai| supportsTypeInner(ai.child, next_seen),
        .pointer => |pi| switch (pi.size) {
            .one, .slice => supportsTypeInner(pi.child, next_seen),
            .many, .c => false,
        },
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (!supportsTypeInner(field.type, next_seen)) break :blk false;
            }
            break :blk true;
        },
        .optional => |oi| supportsTypeInner(oi.child, next_seen),
        .error_union => |ei| supportsTypeInner(ei.payload, next_seen),
        .@"union" => |ui| blk: {
            if (ui.tag_type == null) break :blk false;
            inline for (ui.fields) |field| {
                if (!supportsTypeInner(field.type, next_seen)) break :blk false;
            }
            break :blk true;
        },
        .type,
        .noreturn,
        .comptime_int,
        .comptime_float,
        .undefined,
        .@"fn",
        .frame,
        .@"anyframe",
        .enum_literal,
        .@"opaque",
        .error_set,
        => false,
    };
}

pub fn supportsType(comptime T: type) bool {
    return supportsTypeInner(T, &.{});
}

fn maxAlignmentInner(comptime T: type, comptime seen: []const type) std.mem.Alignment {
    @setEvalBranchQuota(1_000_000);
    if (seenType(seen, T)) return .@"1";
    const next_seen = seen ++ [1]type{T};
    return switch (@typeInfo(T)) {
        .void, .null => .@"1",
        .bool, .int, .float, .vector => std.mem.Alignment.fromByteUnits(@alignOf(T)),
        .@"enum" => |ei| std.mem.Alignment.fromByteUnits(@alignOf(ei.tag_type)),
        .array => |ai| maxAlignmentInner(ai.child, next_seen),
        .pointer => |pi| switch (pi.size) {
            .one => maxAlignmentInner(pi.child, next_seen),
            .slice => maxAlignmentInner(pi.child, next_seen)
                .max(std.mem.Alignment.fromByteUnits(pi.alignment))
                .max(std.mem.Alignment.fromByteUnits(@alignOf(root.Size))),
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| blk: {
            var out: std.mem.Alignment = .@"1";
            inline for (si.fields) |field| {
                out = out.max(maxAlignmentInner(field.type, next_seen));
            }
            break :blk out;
        },
        .optional => |oi| maxAlignmentInner(oi.child, next_seen).max(.@"1"),
        .error_union => |ei| maxAlignmentInner(ei.payload, next_seen).max(std.mem.Alignment.fromByteUnits(@alignOf(u16))),
        .@"union" => |ui| blk: {
            var out: std.mem.Alignment = .@"1";
            if (ui.tag_type) |Tag| out = out.max(std.mem.Alignment.fromByteUnits(@alignOf(Tag)));
            inline for (ui.fields) |field| {
                out = out.max(maxAlignmentInner(field.type, next_seen));
            }
            break :blk out;
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    };
}

pub fn maxAlignmentOf(comptime T: type) std.mem.Alignment {
    @setEvalBranchQuota(1_000_000);
    return maxAlignmentInner(T, &.{});
}

pub fn SerializeBytes(comptime T: type) type {
    return []align(maxAlignmentOf(T).toByteUnits()) u8;
}

fn ReturnType(comptime trusted: bool, comptime T: type) type {
    return if (trusted) T else ValidationError!T;
}

fn containsDynamic(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pi| switch (pi.size) {
            .one, .slice => true,
            .many, .c => false,
        },
        .array => |ai| containsDynamic(ai.child),
        .@"struct" => |si| blk: {
            inline for (si.fields) |field| {
                if (containsDynamic(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |oi| containsDynamic(oi.child),
        .error_union => |ei| containsDynamic(ei.payload),
        .@"union" => |ui| blk: {
            inline for (ui.fields) |field| {
                if (containsDynamic(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn Writer() type {
    return struct {
        buffer: ?[]u8,
        pos: usize = 0,

        fn init(buffer: ?[]u8) @This() {
            return .{ .buffer = buffer };
        }

        fn alignTo(self: *@This(), comptime alignment: usize) ValidationError!void {
            const new_pos = meta.alignForward(self.pos, alignment) catch return error.LengthOverflow;
            if (self.buffer) |buf| {
                if (new_pos > buf.len) return error.NotEnoughBytes;
                if (new_pos > self.pos) @memset(buf[self.pos..new_pos], 0);
            }
            self.pos = new_pos;
        }

        fn writeBytes(self: *@This(), bytes: []const u8) ValidationError!void {
            const end = std.math.add(usize, self.pos, bytes.len) catch return error.LengthOverflow;
            if (self.buffer) |buf| {
                if (end > buf.len) return error.NotEnoughBytes;
                @memcpy(buf[self.pos..end], bytes);
            }
            self.pos = end;
        }

        fn writePod(self: *@This(), comptime T: type, value: T) ValidationError!void {
            var tmp = value;
            try self.alignTo(@alignOf(T));
            try self.writeBytes(std.mem.asBytes(&tmp));
        }
    };
}

fn Reader() type {
    return struct {
        bytes: []const u8,
        pos: usize,
        checked: bool,

        fn init(bytes: []const u8, checked: bool) @This() {
            return .{ .bytes = bytes, .pos = 0, .checked = checked };
        }

        fn initAt(bytes: []const u8, start: usize, checked: bool) @This() {
            return .{ .bytes = bytes, .pos = start, .checked = checked };
        }

        fn alignTo(self: *@This(), comptime alignment: usize) ValidationError!void {
            const new_pos = meta.alignForward(self.pos, alignment) catch return error.LengthOverflow;
            if (self.checked and new_pos > self.bytes.len) return error.NotEnoughBytes;
            self.pos = new_pos;
        }

        fn readBytes(self: *@This(), len: usize) ValidationError![]const u8 {
            const end = std.math.add(usize, self.pos, len) catch return error.LengthOverflow;
            if (self.checked and end > self.bytes.len) return error.NotEnoughBytes;
            const out = self.bytes[self.pos..end];
            self.pos = end;
            return out;
        }

        fn readPod(self: *@This(), comptime T: type) ValidationError!T {
            try self.alignTo(@alignOf(T));
            const bytes = try self.readBytes(@sizeOf(T));
            var out: T = undefined;
            @memcpy(std.mem.asBytes(&out), bytes);
            return out;
        }
    };
}

fn toOutOfBounds(_: anyerror) ValidationError {
    return error.OutOfBounds;
}

fn writeTag(comptime Tag: type, w: *Writer(), tag: Tag) ValidationError!void {
    switch (@typeInfo(Tag)) {
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw: Raw = @intCast(@intFromEnum(tag));
            try w.writePod(Raw, raw);
        },
        .int => try w.writePod(Tag, tag),
        else => @compileError("Unsupported union tag type: " ++ @typeName(Tag)),
    }
}

fn readTag(comptime Tag: type, r: *Reader()) ValidationError!Tag {
    switch (@typeInfo(Tag)) {
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw = try r.readPod(Raw);
            return std.meta.intToEnum(Tag, raw) catch error.InvalidUnionTag;
        },
        .int => return try r.readPod(Tag),
        else => @compileError("Unsupported union tag type: " ++ @typeName(Tag)),
    }
}

fn serializeValue(comptime T: type, w: *Writer(), value: *const T) ValidationError!void {
    switch (@typeInfo(T)) {
        .void, .null => return,
        .bool, .int, .float, .vector => try w.writePod(T, value.*),
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw: Raw = @intCast(@intFromEnum(value.*));
            try w.writePod(Raw, raw);
        },
        .array => |ai| {
            inline for (0..ai.len) |i| {
                try serializeValue(ai.child, w, &value.*[i]);
            }
        },
        .pointer => |pi| switch (pi.size) {
            .one => try serializeValue(pi.child, w, value.*),
            .slice => {
                const len_size: root.Size = meta.castUsize(root.Size, value.*.len) catch return error.LengthOverflow;
                try w.writePod(root.Size, len_size);
                for (value.*) |*elem| {
                    try serializeValue(pi.child, w, elem);
                }
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                var field_copy = @field(value.*, field.name);
                try serializeValue(field.type, w, &field_copy);
            }
        },
        .optional => |oi| {
            if (value.*) |payload| {
                try w.writePod(u8, 1);
                var p = payload;
                try serializeValue(oi.child, w, &p);
            } else {
                try w.writePod(u8, 0);
            }
        },
        .error_union => |ei| {
            if (value.*) |payload| {
                try w.writePod(u8, 1);
                var p = payload;
                try serializeValue(ei.payload, w, &p);
            } else |e| {
                try w.writePod(u8, 0);
                const code: u16 = @intCast(@intFromError(e));
                try w.writePod(u16, code);
            }
        },
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot serialize untagged union: " ++ @typeName(T));
            const tag: Tag = std.meta.activeTag(value.*);
            try writeTag(Tag, w, tag);
            switch (value.*) {
                inline else => |payload| {
                    var p = payload;
                    try serializeValue(@TypeOf(payload), w, &p);
                },
            }
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    }
}

fn skipValue(comptime T: type, r: *Reader()) ValidationError!void {
    switch (@typeInfo(T)) {
        .void, .null => return,
        .bool, .int, .float, .vector => {
            _ = try r.readPod(T);
        },
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw = try r.readPod(Raw);
            _ = std.meta.intToEnum(T, raw) catch return error.InvalidEnumTag;
        },
        .array => |ai| {
            inline for (0..ai.len) |_| {
                try skipValue(ai.child, r);
            }
        },
        .pointer => |pi| switch (pi.size) {
            .one => try skipValue(pi.child, r),
            .slice => {
                const len_size = try r.readPod(root.Size);
                const len = meta.usizeFromAnyInt(len_size) catch return error.LengthOverflow;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    try skipValue(pi.child, r);
                }
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            inline for (si.fields) |field| {
                try skipValue(field.type, r);
            }
        },
        .optional => |oi| {
            const tag = try r.readPod(u8);
            switch (tag) {
                0 => {},
                1 => try skipValue(oi.child, r),
                else => return error.InvalidTag,
            }
        },
        .error_union => |ei| {
            const tag = try r.readPod(u8);
            switch (tag) {
                0 => _ = try r.readPod(u16),
                1 => try skipValue(ei.payload, r),
                else => return error.InvalidTag,
            }
        },
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot skip untagged union: " ++ @typeName(T));
            const tag = try readTag(Tag, r);
            inline for (ui.fields) |field| {
                if (@field(Tag, field.name) == tag) {
                    try skipValue(field.type, r);
                    return;
                }
            }
            return error.InvalidUnionTag;
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    }
}

fn Decoded(comptime T: type) type {
    return struct { value: T };
}

fn returnDecoded(comptime T: type, decoded: Decoded(T)) T {
    return switch (@typeInfo(T)) {
        .error_union => if (decoded.value) |payload| payload else |e| @as(@typeInfo(T).error_union.error_set, @errorCast(e)),
        else => decoded.value,
    };
}

fn decodeValue(comptime T: type, r: *Reader(), gpa: std.mem.Allocator) DeserializeError!Decoded(T) {
    switch (@typeInfo(T)) {
        .void => return .{ .value = {} },
        .null => return .{ .value = null },
        .bool, .int, .float, .vector => return .{ .value = try r.readPod(T) },
        .@"enum" => |ei| {
            const Raw = ei.tag_type;
            const raw = try r.readPod(Raw);
            return .{ .value = std.meta.intToEnum(T, raw) catch return error.InvalidEnumTag };
        },
        .array => |ai| {
            var out: T = undefined;
            inline for (0..ai.len) |i| {
                out[i] = (try decodeValue(ai.child, r, gpa)).value;
            }
            return .{ .value = out };
        },
        .pointer => |pi| switch (pi.size) {
            .one => {
                const child_ptr = try gpa.create(pi.child);
                errdefer gpa.destroy(child_ptr);
                child_ptr.* = (try decodeValue(pi.child, r, gpa)).value;
                return .{ .value = @as(T, child_ptr) };
            },
            .slice => {
                const len_size = try r.readPod(root.Size);
                const len = meta.usizeFromAnyInt(len_size) catch return error.LengthOverflow;
                const alignment = comptime std.mem.Alignment.fromByteUnits(pi.alignment);
                var out = try gpa.alignedAlloc(pi.child, alignment, len);
                errdefer gpa.free(out);
                for (0..len) |i| {
                    out[i] = (try decodeValue(pi.child, r, gpa)).value;
                }
                return .{ .value = @as(T, out) };
            },
            .many, .c => @compileError("Unsupported pointer type in oneserial destructive format: " ++ @tagName(pi.size) ++ " for " ++ @typeName(T)),
        },
        .@"struct" => |si| {
            var out: T = undefined;
            inline for (si.fields) |field| {
                @field(out, field.name) = (try decodeValue(field.type, r, gpa)).value;
            }
            return .{ .value = out };
        },
        .optional => |oi| {
            const tag = try r.readPod(u8);
            var out: T = null;
            switch (tag) {
                0 => {},
                1 => out = (try decodeValue(oi.child, r, gpa)).value,
                else => return error.InvalidTag,
            }
            return .{ .value = out };
        },
        .error_union => |ei| {
            const tag = try r.readPod(u8);
            var out: T = undefined;
            switch (tag) {
                0 => {
                    const code = try r.readPod(u16);
                    const e: anyerror = @errorFromInt(code);
                    out = @as(ei.error_set, @errorCast(e));
                },
                1 => {
                    out = (try decodeValue(ei.payload, r, gpa)).value;
                },
                else => return error.InvalidTag,
            }
            return .{ .value = out };
        },
        .@"union" => |ui| {
            const Tag = ui.tag_type orelse @compileError("Cannot decode untagged union: " ++ @typeName(T));
            const tag = try readTag(Tag, r);
            inline for (ui.fields) |field| {
                if (@field(Tag, field.name) == tag) {
                    const payload = (try decodeValue(field.type, r, gpa)).value;
                    return .{ .value = @unionInit(T, field.name, payload) };
                }
            }
            return error.InvalidUnionTag;
        },
        .type, .noreturn, .comptime_int, .comptime_float, .undefined, .@"fn", .frame, .@"anyframe", .enum_literal, .@"opaque", .error_set => {
            @compileError("Unsupported type in oneserial: " ++ @typeName(T));
        },
    }
}

fn fieldTypeByName(comptime S: type, comptime field_name: []const u8) type {
    const si = @typeInfo(S).@"struct";
    inline for (si.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) return field.type;
    }
    @compileError("Unknown field '" ++ field_name ++ "' on " ++ @typeName(S));
}

fn fieldStart(comptime S: type, comptime field_name: []const u8, bytes: []const u8, start: usize, checked: bool) ValidationError!usize {
    var r = Reader().initAt(bytes, start, checked);
    const si = @typeInfo(S).@"struct";
    inline for (si.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) return r.pos;
        try skipValue(field.type, &r);
    }
    unreachable;
}

fn sliceLen(comptime SliceT: type, bytes: []const u8, start: usize, checked: bool) ValidationError!usize {
    _ = SliceT;
    var r = Reader().initAt(bytes, start, checked);
    const len_size = try r.readPod(root.Size);
    return meta.usizeFromAnyInt(len_size) catch error.LengthOverflow;
}

fn sliceElementStart(comptime SliceT: type, bytes: []const u8, start: usize, index: usize, checked: bool) ValidationError!usize {
    const pi = @typeInfo(SliceT).pointer;
    var r = Reader().initAt(bytes, start, checked);
    const len_size = try r.readPod(root.Size);
    const len = meta.usizeFromAnyInt(len_size) catch return error.LengthOverflow;
    if (checked and index >= len) return error.OutOfBounds;

    var i: usize = 0;
    while (i < index) : (i += 1) {
        try skipValue(pi.child, &r);
    }
    return r.pos;
}

pub fn View(comptime T: type, comptime trusted: bool) type {
    return struct {
        bytes: []const u8,
        start: usize,

        pub fn field(self: @This(), comptime field_name: []const u8) ReturnType(trusted, View(fieldTypeByName(T, field_name), trusted)) {
            if (@typeInfo(T) != .@"struct") {
                @compileError("field() only exists for struct views, got " ++ @typeName(T));
            }
            if (comptime trusted) {
                const s = fieldStart(T, field_name, self.bytes, self.start, false) catch unreachable;
                return .{ .bytes = self.bytes, .start = s };
            }
            const s = fieldStart(T, field_name, self.bytes, self.start, true) catch |err| return toOutOfBounds(err);
            return .{ .bytes = self.bytes, .start = s };
        }

        pub fn get(self: @This()) ReturnType(trusted, blk: {
            switch (@typeInfo(T)) {
                .pointer => |pi| if (pi.size == .one) break :blk View(pi.child, trusted),
                else => {},
            }
            break :blk @This();
        }) {
            switch (@typeInfo(T)) {
                .pointer => |pi| switch (pi.size) {
                    .one => {
                        if (comptime trusted) {
                            return .{ .bytes = self.bytes, .start = self.start };
                        }
                        var r = Reader().initAt(self.bytes, self.start, true);
                        skipValue(pi.child, &r) catch |err| return toOutOfBounds(err);
                        return .{ .bytes = self.bytes, .start = self.start };
                    },
                    .slice => {
                        if (comptime trusted) return self;
                        var r = Reader().initAt(self.bytes, self.start, true);
                        skipValue(T, &r) catch |err| return toOutOfBounds(err);
                        return self;
                    },
                    else => @compileError("get() unsupported for " ++ @typeName(T)),
                },
                else => {
                    if (!containsDynamic(T)) {
                        @compileError("get() is only available for dynamic values, got " ++ @typeName(T));
                    }
                    if (comptime trusted) return self;
                    var r = Reader().initAt(self.bytes, self.start, true);
                    skipValue(T, &r) catch |err| return toOutOfBounds(err);
                    return self;
                },
            }
        }

        pub fn len(self: @This()) ReturnType(trusted, usize) {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .slice) {
                @compileError("len() is only available on slice views, got " ++ @typeName(T));
            }
            if (comptime trusted) {
                return sliceLen(T, self.bytes, self.start, false) catch unreachable;
            }
            return sliceLen(T, self.bytes, self.start, true) catch |err| return toOutOfBounds(err);
        }

        pub fn at(self: @This(), index: usize) ReturnType(trusted, View(@typeInfo(T).pointer.child, trusted)) {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .slice) {
                @compileError("at() is only available on slice views, got " ++ @typeName(T));
            }
            if (comptime trusted) {
                const s = sliceElementStart(T, self.bytes, self.start, index, false) catch unreachable;
                return .{ .bytes = self.bytes, .start = s };
            }
            const s = sliceElementStart(T, self.bytes, self.start, index, true) catch |err| return toOutOfBounds(err);
            return .{ .bytes = self.bytes, .start = s };
        }

        pub fn atUnchecked(self: @This(), index: usize) View(@typeInfo(T).pointer.child, trusted) {
            const ti = @typeInfo(T);
            if (ti != .pointer or ti.pointer.size != .slice) {
                @compileError("atUnchecked() is only available on slice views, got " ++ @typeName(T));
            }
            const s = sliceElementStart(T, self.bytes, self.start, index, false) catch unreachable;
            return .{ .bytes = self.bytes, .start = s };
        }

        pub fn value(self: @This()) ReturnType(trusted, T) {
            var r = Reader().initAt(self.bytes, self.start, !trusted);
            const decoded = decodeValue(T, &r, std.heap.page_allocator) catch |err| {
                if (comptime trusted) unreachable;
                return toOutOfBounds(err);
            };
            const out: T = returnDecoded(T, decoded);
            return out;
        }

        pub fn toOwned(self: @This(), gpa: std.mem.Allocator) DeserializeError!T {
            var r = Reader().initAt(self.bytes, self.start, !trusted);
            const decoded = try decodeValue(T, &r, gpa);
            const out: T = returnDecoded(T, decoded);
            return out;
        }
    };
}

fn validateExact(comptime T: type, bytes: []const u8) ValidationError!void {
    var r = Reader().init(bytes, true);
    try skipValue(T, &r);
    if (r.pos != bytes.len) return error.TooManyBytes;
}

fn decodeRootExact(comptime T: type, bytes: []const u8, checked: bool, gpa: std.mem.Allocator) DeserializeError!Decoded(T) {
    var r = Reader().init(bytes, checked);
    const out = try decodeValue(T, &r, gpa);
    if (checked and r.pos != bytes.len) return error.TooManyBytes;
    return out;
}

pub fn Converter(comptime T: type) type {
    return struct {
        pub const Type = T;
        pub const alignment = maxAlignmentOf(T);
        /// A wrapper around untrusted data.
        /// Bound checks are done on every access
        pub const Untrusted = struct {
            bytes: []const u8,
            view: View(T, false),

            pub fn init(bytes: []const u8) @This() {
                return .{
                    .bytes = bytes,
                    .view = .{ .bytes = bytes, .start = 0 },
                };
            }

            pub fn validate(self: @This()) ValidationError!Trusted {
                try validateExact(T, self.bytes);
                return Trusted.init(self.bytes);
            }

            pub fn unsafeTrusted(self: @This()) Trusted {
                return Trusted.init(self.bytes);
            }

            pub fn toOwned(self: @This(), gpa: std.mem.Allocator) DeserializeError!T {
                const decoded = try decodeRootExact(T, self.bytes, true, gpa);
                const out: T = returnDecoded(T, decoded);
                return out;
            }

            pub fn field(self: @This(), comptime field_name: []const u8) ValidationError!View(fieldTypeByName(T, field_name), false) {
                return self.view.field(field_name);
            }

            pub fn get(self: @This()) ReturnType(false, blk: {
                switch (@typeInfo(T)) {
                    .pointer => |pi| if (pi.size == .one) break :blk View(pi.child, false),
                    else => {},
                }
                break :blk View(T, false);
            }) {
                return self.view.get();
            }

            pub fn len(self: @This()) ValidationError!usize {
                return self.view.len();
            }

            pub fn at(self: @This(), index: usize) ValidationError!View(@typeInfo(T).pointer.child, false) {
                return self.view.at(index);
            }

            pub fn atUnchecked(self: @This(), index: usize) View(@typeInfo(T).pointer.child, false) {
                return self.view.atUnchecked(index);
            }

            pub fn value(self: @This()) ReturnType(false, T) {
                return self.view.value();
            }
        };

        pub const Trusted = struct {
            bytes: []const u8,
            view: View(T, true),

            pub fn init(bytes: []const u8) @This() {
                return .{
                    .bytes = bytes,
                    .view = .{ .bytes = bytes, .start = 0 },
                };
            }

            pub fn toOwned(self: @This(), gpa: std.mem.Allocator) DeserializeError!T {
                const decoded = try decodeRootExact(T, self.bytes, false, gpa);
                const out: T = returnDecoded(T, decoded);
                return out;
            }

            pub fn field(self: @This(), comptime field_name: []const u8) View(fieldTypeByName(T, field_name), true) {
                return self.view.field(field_name);
            }

            pub fn get(self: @This()) ReturnType(true, blk: {
                switch (@typeInfo(T)) {
                    .pointer => |pi| if (pi.size == .one) break :blk View(pi.child, true),
                    else => {},
                }
                break :blk View(T, true);
            }) {
                return self.view.get();
            }

            pub fn len(self: @This()) usize {
                return self.view.len();
            }

            pub fn at(self: @This(), index: usize) View(@typeInfo(T).pointer.child, true) {
                return self.view.at(index);
            }

            pub fn atUnchecked(self: @This(), index: usize) View(@typeInfo(T).pointer.child, true) {
                return self.view.atUnchecked(index);
            }

            pub fn value(self: @This()) T {
                return self.view.value();
            }
        };

        pub const Wrapper = struct {
            memory: SerializeBytes(T),

            pub fn init(value: *const T, gpa: std.mem.Allocator) SerializeError!@This() {
                return .{ .memory = try serializeAlloc(value, gpa) };
            }

            pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
                gpa.free(self.memory);
            }

            /// Create an untrusted wrapper around the data; bound checks are done on every access
            pub fn untrusted(self: @This()) Untrusted {
                return Untrusted.init(self.memory);
            }

            /// Assume that all the pointers do infact point to in-bounds memory.
            /// DANGER: ONLY CALL THIS ON DATA YOU TRUST
            pub fn trustedUnchecked(self: @This()) Trusted {
                return Trusted.init(self.memory);
            }

            /// Do bounds checking and Converter to trusted
            pub fn validate(self: @This()) !Trusted {
                self.untrusted().validate();
            }
        };

        pub fn serializedSize(value: *const T) ValidationError!usize {
            var w = Writer().init(null);
            try serializeValue(T, &w, value);
            return w.pos;
        }

        pub fn serializeAlloc(value: *const T, gpa: std.mem.Allocator) SerializeError!SerializeBytes(T) {
            const size = try serializedSize(value);
            const bytes = try gpa.alignedAlloc(u8, alignment, size);
            errdefer gpa.free(bytes);
            var w = Writer().init(bytes);
            try serializeValue(T, &w, value);
            if (w.pos != size) return error.NoSpaceLeft;
            return bytes;
        }

        pub fn untrusted(bytes: []const u8) Untrusted {
            return Untrusted.init(bytes);
        }

        pub fn trustedUnchecked(bytes: []const u8) Trusted {
            return Trusted.init(bytes);
        }
    };
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
