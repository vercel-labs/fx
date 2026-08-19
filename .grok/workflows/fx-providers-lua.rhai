let meta = #{
    name: "fx-providers-lua",
    description: "Implement ChatGPT, Grok, Cursor, and OpenRouter backends plus Lua, viewers, image paste, and terminal",
    phases: [
        #{ title: "Scout", detail: "Map provider, Lua, viewer, paste, and terminal seams" },
        #{ title: "OpenAI-compatible", detail: "Add ModelBackend and Chat Completions transport" },
        #{ title: "Subscription OAuth", detail: "Add ChatGPT, Grok, and Cursor login adapters" },
        #{ title: "Lua", detail: "Vendor Lua 5.4 and ship fx.command, keymap, hook, opt" },
        #{ title: "Viewers and paste", detail: "Add code viewer, diff viewer, and image copy-paste" },
        #{ title: "Terminal and LSP", detail: "Close embedded-terminal gaps and add optional fx.lsp" },
        #{ title: "Verify", detail: "Build, format, smoke ./zig-out/bin/fx, open a draft PR" },
    ],
};

fn text_of(value) {
    if type_of(value) == "string" {
        value
    } else {
        json_encode(value)
    }
}

fn run_agent(label, prompt, capability_mode) {
    log("launching " + label);
    let result = agent(
        prompt,
        #{
            label: label,
            capability_mode: capability_mode,
            output_schema: #{
                "type": "object",
                "properties": #{
                    "status": #{
                        "type": "string",
                        "enum": ["ok", "blocked", "failed"],
                    },
                    "summary": #{ "type": "string" },
                    "files_changed": #{
                        "type": "array",
                        "items": #{ "type": "string" },
                    },
                    "blockers": #{
                        "type": "array",
                        "items": #{ "type": "string" },
                    },
                },
                "required": ["status", "summary"],
            },
        },
    );
    if !result.success {
        pause("verification", label + " did not return a structured result.");
    }
    if result.output.status != "ok" {
        pause("verification", label + " reported " + text_of(result.output.status) + ": " + text_of(result.output.summary));
    }
    result
}

let branch = "feat-providers-lua-viewer";
if args != () && args.branch != () && args.branch != "" {
    branch = args.branch;
}

let plan_path = "/Users/jack/workspace/fx/.grok/workflows/fx-providers-lua-plan.md";
let notes_path = "/Users/jack/workspace/fx/.grok/workflows/fx-providers-lua-notes.md";
let grok_ref = "https://github.com/xai-org/grok-build";
let skip_scout = args != () && args.skip_scout == true;
let rules = "Follow /Users/jack/workspace/fx/Agents.md strictly. Work only in /Users/jack/workspace/fx on branch "
    + branch
    + ". Do not commit to main. Do not grow src/main.zig with leaf logic. Do not put provider keys or OAuth tokens in project .fx.json. Do not embed or fork Neovim. Do not add a second agent loop. Do not send OpenAI-compatible payloads through the Gateway v3 parser. Use zig fmt on src/, build with zig build, and verify only with ./zig-out/bin/fx (never PATH fx). Keep pub surface minimal. Allocator is passed explicitly. Profile-owned keys stay in ~/.fx/settings.json. Read the plan at "
    + plan_path
    + " and the scout notes at "
    + notes_path
    + ". Product name is fx. CLI flags are kebab-case. Identifiers are snake_case. Types are PascalCase. Continue from existing work on this branch; do not redo completed PRs.";

phase("Scout");
if skip_scout {
    log("skipping scout; using existing notes at " + notes_path);
} else {
    run_agent(
        "scout-seams",
        rules
            + " You are scouting only. capability is read-only. Read the plan. Map current fx seams for gateway auth, login/setup, image attachments, terminal host, highlight, and AlternateScreenOwner. Also inspect "
            + grok_ref
            + " for image clipboard paste, inline diff viewer, code viewer, and embedded terminal behavior. Write findings to "
            + notes_path
            + " covering files to touch, contracts to reuse, and grok-build behaviors to port. Do not edit src/. status=ok when the notes file exists and is specific.",
        "read-only",
    );
}

phase("OpenAI-compatible");
run_agent(
    "openai-compatible",
    rules
        + " Implement PR 1 from the plan: ModelBackend (vercel_gateway | chatgpt | grok | cursor | openai_compatible), config, Chat Completions builder/parser, /setup URL+key, catalog, docs. Default remains Vercel Gateway. Ownership: src/core/providers/ for backend kind/config/catalog; src/gateway/openai_compatible.zig for SSE Chat Completions; src/ui/ only for setup picker. Env: FX_PROVIDER, FX_OPENAI_BASE_URL, FX_OPENAI_API_KEY. Persist provider and openai_compatible under ~/.fx/settings.json. Adapt into existing stream_provider.Provider / GatewayCompletion. Add Zig unit tests next to the parser and backend resolver. Create or reuse branch "
        + branch
        + " from current HEAD if needed, implement, zig fmt src/, zig build, focused tests, commit. status=ok only after the binary builds and a local fake /v1/chat/completions path is covered by tests.",
    "all",
);

phase("Subscription OAuth");
run_agent(
    "chatgpt-oauth",
    rules
        + " Implement PR 2: ChatGPT subscription OAuth. Reuse PKCE from src/core/mcp/mcp_auth.zig. Session under ~/.fx/providers/chatgpt/auth.json. Responses API adapter in src/gateway/openai_responses.zig. Issuer https://auth.openai.com. Wire chatgpt.com/backend-api/codex. Commands: fx login chatgpt and /login chatgpt. Bare fx login stays Vercel. Add /setup ChatGPT option. Models: Codex catalog only; do not invent ids. Fake-issuer unit/e2e dry path. Commit on "
        + branch
        + ". status=ok after build and focused tests.",
    "all",
);
run_agent(
    "grok-oauth",
    rules
        + " Implement PR 3: Grok Build / SuperGrok subscription OAuth. Device-code against accounts.x.ai using existing oauth.zig. Session under ~/.fx/providers/grok/. Transport is OpenAI-compatible with the subscription token. /login grok. Models from Grok Build catalog once fetch exists. Fake-issuer dry path. Commit on "
        + branch
        + ". status=ok after build and focused tests.",
    "all",
);
run_agent(
    "cursor-oauth",
    rules
        + " Implement PR 4: Cursor subscription OAuth. PKCE + loopback like ChatGPT. Session under ~/.fx/providers/cursor/. Cursor OpenAI-compatible agent endpoint and required headers live in one adapter file so ToS breakage can drop the adapter without touching the agent loop. /login cursor. Fail cleanly with their error body. Fake-issuer dry path. Commit on "
        + branch
        + ". status=ok after build and focused tests.",
    "all",
);

phase("Lua");
run_agent(
    "embed-lua",
    rules
        + " Implement PR 5: vendor Lua 5.4 C under third_party/lua/ and compile from build.zig. No LuaJIT. Ownership src/core/scripting/. Native CLI/TUI only; skip WASM/NAPI. Load ~/.fx/init.lua then <workspace>/.fx/init.lua. Errors are notices, never abort startup. Sandbox: no os.execute/io.popen unless permissions grant it. File reads default to ~/.fx/lua, ~/.fx/pack, and workspace .fx/. API v1: fx.command, fx.keymap, fx.hook, fx.notify, fx.opt, fx.model, fx.provider, fx.view.open. Register Lua commands into the existing slash registry. Commands /lua and /lua reload. Add tests that a broken init.lua does not crash and that /hello from init.lua registers. Commit on "
        + branch
        + ". status=ok after zig build and those tests.",
    "all",
);

phase("Viewers and paste");
run_agent(
    "code-diff-viewer",
    rules
        + " Implement the read-only code viewer and a first-class diff viewer. Sixth AlternateScreenOwner: code_viewer (and reuse or add a sibling owner for diffs if required by the exclusive-owner invariant). Same enter/leave contract as the other owners. Reuse src/ui/render_engine/code_highlight.zig. Features: line numbers, search, goto line, /view <path>, fx.view.open, tool-result affordance for read_file and diffs. Diff viewer should be comparable to grok-build's inline diff review: hunk navigation, accept/reject is NOT required (agent tools write; this is view-only) but side-by-side or unified hunk display, file path, and restore of the main grid on quit are required. Update CONTRIBUTING.md alternate-screen list. No Treesitter, no modal editor. Commit on "
        + branch
        + ". Exercise ./zig-out/bin/fx if a non-TTY path exists; otherwise add a Zig layout/unit test. status=ok after build and tests.",
    "all",
);
run_agent(
    "image-copy-paste",
    rules
        + " Port grok-build image copy-paste into fx. Read existing src/core/images/image_attachments.zig and composer/paste input. Match grok-build behavior: Ctrl+V / OSC 52 or platform clipboard image, drag-drop if already handled, png/jpg/gif/webp, attach as vision input not just a path. Keep persistence and permissions consistent with fx. Add tests for the paste decoder / attachment path. See "
        + grok_ref
        + " and local grok-build notes. Commit on "
        + branch
        + ". status=ok after build and focused tests.",
    "all",
);

phase("Terminal and LSP");
run_agent(
    "embedded-terminal",
    rules
        + " Close embedded-terminal gaps versus grok-build while keeping fx's existing TerminalHost / AlternateScreenOwner.terminal_session. Do not add a second terminal engine. Humans still edit in $EDITOR via hosted child after the write lease. Confirm detach restores chrome, composer, cursor, paste, mouse, focus, keyboard. Add any missing empty-command interactive shell startup if not already shipped. Docs only if user-facing behavior changes. Commit on "
        + branch
        + " only if there is a real gap; if already at parity, status=ok with summary of existing seams and no dummy commit.",
    "all",
);
run_agent(
    "lua-lsp",
    rules
        + " Implement PR 7: optional Lua LSP client. fx.lsp.start({name, cmd, root}). JSON-RPC client only. No bundled servers. Diagnostics in the viewer; go-to-definition reopens the viewer. Permission-gated process spawn. Later-PR quality is fine but it must compile and have unit tests for the client framing. Commit on "
        + branch
        + ". status=ok after build and tests.",
    "all",
);

phase("Verify");
let verify = run_agent(
    "verify-and-pr",
    rules
        + " Final gate on branch "
        + branch
        + ". Run zig fmt --check src/, zig build, and the focused tests for providers, lua, viewer, images, and terminal. Exercise ./zig-out/bin/fx help and any non-interactive new commands (fx login --help, provider-related help). Do not claim TUI happy-path if you cannot attach a TTY; say so in the summary. If checks pass, push "
        + branch
        + " to the user's origin (keejkrej/fx if that is origin) and open a draft PR with type: feature. Do not mark ready. Do not merge. status=ok if the branch is pushed and a draft PR URL exists, or blocked if gh/auth is missing after a successful local verify.",
    "all",
);

complete(#{
    branch: branch,
    plan: plan_path,
    verify: verify.output,
});
