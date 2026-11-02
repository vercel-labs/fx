const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;
