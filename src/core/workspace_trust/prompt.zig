//! State of the "Folder access" screen: what the answer covers, the rows it
//! lists, the selected choice, and what each key does. Pure: no I/O, no
//! allocation.

const std = @import("std");
const workspace_trust = @import("workspace_trust.zig");

pub const Choice = enum { allow, exit };

/// The keys the screen understands; the app maps terminal bytes to them.
pub const Input = enum { previous, next, choose_allow, choose_exit, confirm, cancel };

pub const Outcome = enum { stay, allow, exit };

/// One line of "This folder has", such as `AGENTS.md` and `instructions for the agent`.
pub const Row = struct { name: []const u8, detail: []const u8 };

pub const Prompt = struct {
    /// The real path of the start folder (borrowed).
    folder: []const u8,
    cover: workspace_trust.Cover,
    /// Borrowed. The owner may replace them, for example when the skill catalog loads.
    rows: []const Row = &.{},
    selected: Choice = .allow,

    pub fn press(self: *Prompt, input: Input) Outcome {
        switch (input) {
            .previous => {
                self.selected = .allow;
                return .stay;
            },
            .next => {
                self.selected = .exit;
                return .stay;
            },
            .choose_allow => return .allow,
            .choose_exit, .cancel => return .exit,
            .confirm => return if (self.selected == .allow) .allow else .exit,
        }
    }
};

const law_rounds = 1000;
const law_seed = 0x7a11;
const max_inputs = 8;
const all_inputs = std.enums.values(Input);

fn newPrompt() Prompt {
    return .{ .folder = "/r", .cover = .this_folder };
}

fn randomInput(random: std.Random) Input {
    return all_inputs[random.uintLessThan(usize, all_inputs.len)];
}

/// `last_move` starts as `.previous`, so an unmoved prompt allows by default.
fn expectedOutcome(ending: Input, last_move: Input) Outcome {
    return switch (ending) {
        .choose_allow => .allow,
        .confirm => if (last_move == .previous) .allow else .exit,
        .choose_exit, .cancel => .exit,
        .previous, .next => .stay,
    };
}

test "the screen allows by default" {
    var prompt = newPrompt();
    try std.testing.expectEqual(Outcome.allow, prompt.press(.confirm));
}

test "moving down then confirming exits" {
    var prompt = newPrompt();
    try std.testing.expectEqual(Outcome.stay, prompt.press(.next));
    try std.testing.expectEqual(Outcome.exit, prompt.press(.confirm));
}

test "moving back up then confirming allows" {
    var prompt = newPrompt();
    _ = prompt.press(.next);
    try std.testing.expectEqual(Outcome.stay, prompt.press(.previous));
    try std.testing.expectEqual(Outcome.allow, prompt.press(.confirm));
}

test "a digit chooses at once" {
    var prompt = newPrompt();
    try std.testing.expectEqual(Outcome.exit, prompt.press(.choose_exit));
    _ = prompt.press(.next);
    try std.testing.expectEqual(Outcome.allow, prompt.press(.choose_allow));
}

test "escape exits from either choice" {
    var prompt = newPrompt();
    try std.testing.expectEqual(Outcome.exit, prompt.press(.cancel));
    _ = prompt.press(.next);
    try std.testing.expectEqual(Outcome.exit, prompt.press(.cancel));
}

test "only allow chosen or confirmed allows, on random key sequences" {
    var prng = std.Random.DefaultPrng.init(law_seed);
    const random = prng.random();
    var judged: usize = 0;
    for (0..law_rounds) |_| {
        var prompt = newPrompt();
        var last_move: Input = .previous;
        const length = 1 + random.uintLessThan(usize, max_inputs);
        for (0..length) |_| {
            const input = randomInput(random);
            if (input == .previous or input == .next) last_move = input;
            const outcome = prompt.press(input);
            if (outcome == .stay) continue;
            try std.testing.expectEqual(expectedOutcome(input, last_move), outcome);
            judged += 1;
            break;
        }
    }
    try std.testing.expect(judged > law_rounds / 2);
}
