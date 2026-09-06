pub const Token = struct {
    context: *anyopaque,
    identity: u64,
    commit_fn: *const fn (*anyopaque, u64) anyerror!void,
    cancel_fn: *const fn (*anyopaque, u64) void,

    pub fn commit(self: Token) !void {
        return self.commit_fn(self.context, self.identity);
    }

    pub fn cancel(self: Token) void {
        self.cancel_fn(self.context, self.identity);
    }
};
