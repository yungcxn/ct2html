const std = @import("std");

pub const Kind = enum(u8) {
    ItemListOpen,
    ItemListClose,
};

kind: Kind,
before_node: usize,
