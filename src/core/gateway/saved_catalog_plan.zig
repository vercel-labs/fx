//! When fx uses the model catalog it saved, and when a request waits for the
//! network. It does no I/O, reads no clock, and never allocates: the caller
//! passes the times and the load's state in. `tests/tla/catalog_open/CatalogOpen.tla`
//! models these rules.
const std = @import("std");

/// The oldest saved catalog a start uses. An older one counts as none, so
/// the start waits for AI Gateway as it does with no saved catalog.
pub const max_age_ms: i64 = 24 * std.time.ms_per_hour;

pub const Start = enum {
    /// The saved catalog is too old, or its time says nothing: wait for a
    /// fresh one where a request needs it.
    cold,
    /// Use the saved catalog. It is younger than the refresh interval, so
    /// fx fetches none until that interval has passed since it was saved.
    use,
    /// Use the saved catalog, and fetch a fresh one in the background.
    use_and_fetch,
};

/// What a start does with a catalog saved at `saved_ms`, at `now_ms`, both on
/// the wall clock. A time after `now_ms` comes from a clock that moved back,
/// so the catalog's age is unknown.
pub fn start(saved_ms: i64, now_ms: i64, refresh_interval_ms: i64) Start {
    if (saved_ms > now_ms) return .cold;
    const age_ms = now_ms - saved_ms;
    if (age_ms >= max_age_ms) return .cold;
    if (age_ms < refresh_interval_ms) return .use;
    return .use_and_fetch;
}

pub const Request = enum {
    /// Go on with the catalog fx has.
    go_on,
    /// A load has ended: take its result now. Taking it never waits.
    take_landed,
    /// The catalog is due for a refresh: start a load in the background and
    /// go on with the catalog fx has.
    start_background,
    /// fx has no catalog for this access, or cannot load one in the
    /// background: load it and wait, within the connect deadline.
    wait,
};

pub const RequestState = struct {
    /// fx holds a catalog for the request's provider and access.
    has_catalog: bool,
    /// The catalog never loaded, its access changed, or its refresh
    /// interval has passed.
    due: bool,
    /// A load runs for the request's provider and access.
    load_running: bool,
    /// That load has ended.
    load_landed: bool,
    /// The provider can load on a thread of its own.
    can_load_in_background: bool,
};

/// What a request that reads the catalog does. Once fx holds a catalog for
/// the request's access, no request waits for the network.
pub fn request(state: RequestState) Request {
    if (state.load_landed) return .take_landed;
    if (!state.has_catalog) return if (state.due or state.load_running) .wait else .go_on;
    if (state.load_running or !state.due) return .go_on;
    return if (state.can_load_in_background) .start_background else .wait;
}

const minute_ms = std.time.ms_per_min;

test "saved catalog plan: a start uses a saved catalog younger than a day and fetches once it is five minutes old" {
    const now: i64 = 100 * std.time.ms_per_day;
    const interval: i64 = 5 * minute_ms;
    try std.testing.expectEqual(Start.use, start(now, now, interval));
    try std.testing.expectEqual(Start.use, start(now - interval + 1, now, interval));
    try std.testing.expectEqual(Start.use_and_fetch, start(now - interval, now, interval));
    try std.testing.expectEqual(Start.use_and_fetch, start(now - max_age_ms + 1, now, interval));
    try std.testing.expectEqual(Start.cold, start(now - max_age_ms, now, interval));
    // A clock that moved back says nothing of the saved catalog's age.
    try std.testing.expectEqual(Start.cold, start(now + 1, now, interval));
    // A provider that never refreshes still fetches the catalog it saved.
    try std.testing.expectEqual(Start.use_and_fetch, start(now, now, 0));
}

test "saved catalog plan: a request never waits once fx holds a catalog for its access" {
    for ([_]bool{ false, true }) |due| for ([_]bool{ false, true }) |running| for ([_]bool{ false, true }) |landed| {
        if (landed and !running) continue;
        const got = request(.{ .has_catalog = true, .due = due, .load_running = running, .load_landed = landed, .can_load_in_background = true });
        try std.testing.expect(got != .wait);
    };
    try std.testing.expectEqual(Request.start_background, request(.{ .has_catalog = true, .due = true, .load_running = false, .load_landed = false, .can_load_in_background = true }));
    try std.testing.expectEqual(Request.go_on, request(.{ .has_catalog = true, .due = true, .load_running = true, .load_landed = false, .can_load_in_background = true }));
    try std.testing.expectEqual(Request.go_on, request(.{ .has_catalog = true, .due = false, .load_running = false, .load_landed = false, .can_load_in_background = true }));
    try std.testing.expectEqual(Request.take_landed, request(.{ .has_catalog = true, .due = false, .load_running = true, .load_landed = true, .can_load_in_background = true }));
}

test "saved catalog plan: without a catalog a request waits for the load, and a provider that loads inline refreshes inline" {
    try std.testing.expectEqual(Request.wait, request(.{ .has_catalog = false, .due = true, .load_running = false, .load_landed = false, .can_load_in_background = true }));
    try std.testing.expectEqual(Request.wait, request(.{ .has_catalog = false, .due = false, .load_running = true, .load_landed = false, .can_load_in_background = true }));
    try std.testing.expectEqual(Request.take_landed, request(.{ .has_catalog = false, .due = true, .load_running = true, .load_landed = true, .can_load_in_background = true }));
    // A failed catalog whose retry is not yet due answers with fallbacks.
    try std.testing.expectEqual(Request.go_on, request(.{ .has_catalog = false, .due = false, .load_running = false, .load_landed = false, .can_load_in_background = true }));
    try std.testing.expectEqual(Request.wait, request(.{ .has_catalog = true, .due = true, .load_running = false, .load_landed = false, .can_load_in_background = false }));
}
