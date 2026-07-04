buf: []const u8,
cursor: usize,

pub fn init(buf: []const u8) @This() {
    return @This(){
        .buf = buf,
        .cursor = 0,
    };
}

pub fn pop(self: *@This()) ?u8 {
    if (self.cursor >= self.buf.len) return null;
    defer self.cursor += 1;
    return self.buf[self.cursor];
}

pub fn peek(self: *@This()) ?u8 {
    if (self.cursor >= self.buf.len) return null;
    return self.buf[self.cursor];
}

// on null, self.cursor is at end (exc) of buffer
pub fn take_exc(self: *@This(), delim: u8) ?[]const u8 {
    const start = self.cursor;
    while (self.cursor < self.buf.len) : (self.cursor += 1) {
        if (self.buf[self.cursor] == delim) {
            const result = self.buf[start..self.cursor];
            self.cursor += 1; // skip delim
            return result;
        }
    }
    return null;
}
