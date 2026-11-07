//! Test root for the footer reclaim runtime driver
//! (`tests/tla/drivers/transcript_window/footer-runtime-to-spec.ts`): it builds
//! `src/ui/resize_tests.zig` alone, so the driver and the runtime mutations in
//! `tests/tla/drivers/transcript_window/mutations.ts` run the real transcript
//! runtime without compiling every fx test.

test {
    _ = @import("ui/resize_tests.zig");
}
