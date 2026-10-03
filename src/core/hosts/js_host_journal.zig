//! The JavaScript host's libfx journal, on WebAssembly. Appends travel as
//! ACP notifications on both backends; only the flush needs this import,
//! because a WebAssembly core cannot await an ACP response.

/// Resolves to 0 once the host holds every event sent so far, or to a
/// negative value when an append failed.
extern "fx" fn fx_journal_flush() i32;

pub fn flush() error{JournalFlushFailed}!void {
    if (fx_journal_flush() != 0) return error.JournalFlushFailed;
}
