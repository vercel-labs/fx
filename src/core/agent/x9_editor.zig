const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const editor_environment_variable = "FX_EXPERIMENT_X9_EDITOR";

pub const EditorArm = enum { control, patch_v3 };

pub const Arms = struct {
    editor: EditorArm = .control,

    pub fn additionalVisibleToolNames(self: Arms) ?[]const []const u8 {
        return if (self.editor == .patch_v3) patch_tool_names[0..] else null;
    }
};

const patch_tool_names = [_][]const u8{"apply_patch"};

pub const ParseError = error{
    InvalidX9EditorArm,
};

pub fn parse(editor: ?[]const u8) ParseError!Arms {
    return .{
        .editor = if (editor) |value|
            std.meta.stringToEnum(EditorArm, value) orelse
                return error.InvalidX9EditorArm
        else
            .control,
    };
}

pub fn currentArms() ParseError!Arms {
    return parse(io_mod.getenv(editor_environment_variable));
}

test "X9 editor defaults to behavior-neutral control" {
    const arms = try parse(null);
    try std.testing.expectEqual(EditorArm.control, arms.editor);
    try std.testing.expect(arms.additionalVisibleToolNames() == null);
}

test "X9 patch arm adds the transactional editor" {
    const arms = try parse("patch_v3");
    try std.testing.expectEqualStrings("apply_patch", arms.additionalVisibleToolNames().?[0]);
}

test "X9 editor rejects unknown arms" {
    try std.testing.expectError(error.InvalidX9EditorArm, parse("patch"));
}
