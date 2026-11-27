//! Personal keyboard shortcuts: the chord grammar, the profile's shortcut map,
//! and the rule that says whether a model preset may be applied.
//!
//! Outside code imports only this file. The folder imports only the standard
//! library, shared basics, and model configuration. It never imports the
//! settings store, the UI, `main.zig`, or the app runtime. The profile reader
//! (`core/config/profile_shortcuts.zig`) and the app glue
//! (`core/app/personal_shortcut_runtime.zig`) stay outside for those reasons.

const chord = @import("chord.zig");
const shortcut_map = @import("shortcut_map.zig");
const check = @import("check.zig");

pub const Chord = chord.Chord;
pub const Reserved = chord.Reserved;
pub const reserved = chord.reserved;
pub const fromControlByte = chord.fromControlByte;
pub const fromLegacyAlt = chord.fromLegacyAlt;
pub const fromKitty = chord.fromKitty;
pub const fromNavigationFinal = chord.fromNavigationFinal;
pub const fromSs3Final = chord.fromSs3Final;
pub const fromTildeCode = chord.fromTildeCode;

pub const Map = shortcut_map.Map;
pub const Preset = shortcut_map.Preset;
pub const Problem = shortcut_map.Problem;
pub const reservedEntry = shortcut_map.reservedEntry;
pub const parseAction = shortcut_map.parseAction;
pub const parseJsonObject = shortcut_map.parseJsonObject;
pub const parseJsonObjectChecked = shortcut_map.parseJsonObjectChecked;
pub const key_grammar_description = shortcut_map.key_grammar_description;
pub const max_key_bytes = shortcut_map.max_key_bytes;
pub const max_entries = shortcut_map.max_entries;
pub const max_command_bytes = shortcut_map.max_command_bytes;

pub const PresetRefusal = check.Refusal;
pub const PresetFacts = check.Facts;
pub const checkPreset = check.check;

test {
    _ = chord;
    _ = shortcut_map;
    _ = check;
}
