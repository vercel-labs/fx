const std = @import("std");
const prompt_history_store = @import("../session/prompt_history_store.zig");

pub fn HistoryRuntime(comptime App: type) type {
    return struct {
        /// The workspace a prompt history is kept for. A host workspace owns
        /// the root, as it does for tools and turns; otherwise the app's
        /// local workspace does. Borrowed from the app.
        pub fn promptHistoryRoot(app: *const App) []const u8 {
            if (comptime @hasDecl(App, "workspaceHostInfo")) {
                if (app.workspaceHostInfo()) |info| return info.root();
            }
            return app.workspace_root;
        }

        pub fn installPromptHistory(
            app: *App,
            entries: []const prompt_history_store.LoadedPromptHistoryEntry,
        ) !void {
            var texts: std.ArrayList([]const u8) = .empty;
            defer texts.deinit(app.alloc);
            try texts.ensureTotalCapacity(app.alloc, entries.len);
            for (entries) |entry| texts.appendAssumeCapacity(entry.text);
            try app.input_runtime.composer_history.installTextEntries(
                app.alloc,
                texts.items,
            );
        }

        pub fn loadAndInstallPromptHistory(app: *App) !void {
            const entries = try app.prompt_history.loadRecent(
                app.alloc,
                promptHistoryRoot(app),
                100,
            );
            defer prompt_history_store.freeLoadedEntries(app.alloc, entries);
            try installPromptHistory(app, entries);
        }
    };
}
