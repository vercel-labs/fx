const builtin = @import("builtin");

pub const is_wasm = builtin.target.os.tag == .wasi;
