const std = @import("std");

pub fn sign(v: anytype) @TypeOf(v) {
    return if (v >= 0) 1 else -1;
}

pub fn with_size(T: type, comptime size: std.lang.Type.Pointer.Size) type {
    return mod_ptr_t(T, "size", size);
}

pub fn copy_const(T: type, U: type) type {
    return mod_ptr_t(U, "const", is_const(T));
}

pub fn optional(val: anytype) if (is_type(@TypeOf(val), "optional")) @TypeOf(val) else ?@TypeOf(val) {
    return val;
}

pub fn log_return(val: anytype) @TypeOf(val) {
    if (@TypeOf(val) == type)
        @compileLog("Returning: " ++ @typeName(val))
    else
        @compileLog("Returning: " ++ @typeName(@TypeOf(val)));
    return val;
}

pub fn mod_ptr_t(T: type, comptime field: []const u8, comptime val: anytype) type {
    const is_optional = is_type(T, "optional");

    const old = if (is_optional) @typeInfo(T).optional.child else T;

    comptime var new = @typeInfo(old).pointer;

    if (@hasField(std.lang.Type.Pointer.Attributes, field)) {
        @field(new.attrs, field) = val;
    } else {
        @field(new, field) = val;
    }

    const ret = @Pointer(
        new.size,
        new.attrs,
        new.child,
        std.lang.Type.Pointer.sentinel(new),
    );

    return if (is_optional) ?ret else ret;
}

pub fn enum_len(T: type) usize {
    return @typeInfo(T).@"enum".field_names.len;
}

pub fn is_type(T: type, comptime name: []const u8) bool {
    return @as(std.meta.Tag(std.lang.Type), @typeInfo(T)) == @field(std.meta.Tag(std.lang.Type), name);
}

pub fn is_const(T: type) bool {
    return @typeInfo(T).pointer.attrs.@"const";
}

pub fn typeFromTag(T: type, comptime tag: std.meta.Tag(T)) type {
    return @TypeOf(@field(@unionInit(T, @tagName(tag), undefined), @tagName(tag)));
}

pub fn tagFromType(T: type, U: type) std.meta.Tag(T) {
    const info = @typeInfo(T).@"union";
    inline for (info.field_types, info.field_names) |field_type, field_name| {
        if (U == field_type) {
            return @field(T, field_name);
        }
    }
    @compileError("No matching tag for type " ++ @typeName(U) ++ " in Union " ++ @typeName(T));
}

pub fn fn_error(comptime fun: anytype) ?type {
    const return_type = @typeInfo(@TypeOf(fun)).@"fn".return_type.?;

    return if (is_type(return_type, "error_union")) @typeInfo(return_type).error_union.error_set else null;
}

pub fn param_type(comptime fun: anytype, idx: comptime_int) type {
    return @TypeOf(fun).@"fn".params[idx].type.?;
}

pub fn if_not_null(comptime fun: anytype) fn (?param_type(fun, 0)) void {
    return struct {
        pub fn function(arg: ?param_type(fun, 0)) void {
            if (arg) |a| {
                _ = fun(a);
            }
        }
    }.function;
}

pub fn pack_t(s: type) type {
    const info = @typeInfo(s).@"struct";
    const Attributes = std.lang.Type.Struct.FieldAttributes;

    return @Struct(
        std.lang.Type.ContainerLayout.@"packed",
        info.backing_integer,
        info.field_names,
        info.field_types,
        &@as(
            [info.field_attrs.len]Attributes,
            @splat(Attributes{
                .@"align" = null,
                .@"comptime" = false,
            }),
        ),
    );
}

pub fn pack(s: anytype) pack_t(@TypeOf(s)) {
    const T = @TypeOf(s);
    const fields = @typeInfo(T).@"struct".field_names;
    var packed_struct: pack_t(T) = undefined;

    inline for (fields) |field| {
        @field(packed_struct, field) = @field(s, field);
    }

    return packed_struct;
}
