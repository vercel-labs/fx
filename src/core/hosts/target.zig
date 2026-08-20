const builtin = @import("builtin");

pub const is_wasm = builtin.os.tag == .wasi;
pub const supports_ipython = builtin.os.tag == .linux or builtin.os.tag == .macos;
