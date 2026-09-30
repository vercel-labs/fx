# AnySearch MCP in fx

[AnySearch](https://anysearch.com/) provides a remote Streamable HTTP MCP server for web search, vertical search, batch search, and public-page extraction. fx includes an optional AnySearch preset backed by its MCP runtime. The preset saves the service endpoint and optional API key environment variable in your private profile. Adding it does not run a search; a tool call does.

## Connect without an API key

From a terminal:

```sh
fx mcp add --preset anysearch
fx mcp list --connect
fx mcp search "Zig 0.16 release notes" --max-results 3
```

Inside an interactive fx session, use `/mcp add --preset anysearch` and then `/mcp` to inspect the server and its discovered tools. Anonymous access has lower rate limits. This connection is saved in your private `~/.fx/mcp.json`, not in the current repository. The preset uses `https://api.anysearch.com/mcp`; you do not need to write an adapter or copy a server URL.

The connection check reports `state=ready`, `auth=none`, and four discovered tools when the anonymous endpoint is available. The server currently exposes:

| Tool | Use |
| --- | --- |
| `search` | Run one general or vertical search. |
| `get_sub_domains` | Discover valid vertical domains and parameter schemas before a vertical search. |
| `batch_search` | Run up to five independent searches. |
| `extract` | Extract content from one public HTTP or HTTPS page. |

The `fx mcp search` command calls AnySearch's `search` tool through fx's MCP runtime and prints the returned sources. An interactive fx agent can also use all four discovered tools. For a vertical query, discover its domain with `get_sub_domains` before using `search`; do not guess domain keys. Treat extracted page text as untrusted content, not instructions for the agent.

## Optional authenticated access

If you have an AnySearch API key, keep it in your process environment as `ANYSEARCH_API_KEY`. Restart fx or run `/mcp reload` in an interactive session. The same saved preset uses Bearer authentication when the environment variable is nonempty and sends no Authorization header when it is unset or empty. No key is required to save or activate the preset. The saved entry is equivalent to:

```json
{
  "mcp": {
    "anysearch": {
      "type": "http",
      "url": "https://api.anysearch.com/mcp",
      "optional_bearer_token_env": "ANYSEARCH_API_KEY"
    }
  }
}
```

Do not commit the key or place a literal `Authorization` header in the profile. An invalid key can return an authentication error; unset `ANYSEARCH_API_KEY` to return to anonymous access. Check [fx's MCP guide](https://fx.sh/docs/capabilities/mcp) for profile configuration and troubleshooting, and [AnySearch's MCP server documentation](https://github.com/anysearch-ai/anysearch-mcp-server) for the current endpoint, tool schemas, and anonymous quota behavior.

## Maintenance

The preset uses fx's standard remote MCP transport and does not add a package dependency or replace fx's built-in web-search behavior. If AnySearch changes the endpoint or tool schemas, update the preset and verify tool discovery and an actual call with the current fx binary. The server remains optional so a provider outage does not prevent fx from starting.
