# AnySearch MCP with fx

[AnySearch](https://anysearch.com/) provides a remote Streamable HTTP MCP server for web search, vertical search, batch search, and public-page extraction. fx can connect to it through its existing MCP client. The connection is optional and makes outbound requests only after you configure and use it.

## Connect without an API key

From a terminal:

```sh
fx mcp add --transport http anysearch https://api.anysearch.com/mcp
fx mcp list --connect
```

Inside an interactive fx session, use `/mcp add --transport http anysearch https://api.anysearch.com/mcp` and then `/mcp` to inspect the server and its discovered tools. Anonymous access has lower rate limits. This connection is saved in your private `~/.fx/mcp.json`, not in the current repository.

The connection check reports `state=ready`, `auth=none`, and four discovered tools when the anonymous endpoint is available. The server currently exposes:

| Tool | Use |
| --- | --- |
| `search` | Run one general or vertical search. |
| `get_sub_domains` | Discover valid vertical domains and parameter schemas before a vertical search. |
| `batch_search` | Run up to five independent searches. |
| `extract` | Extract content from one public HTTP or HTTPS page. |

In fx, ask for one general search first and inspect the returned sources. For a vertical query, discover its domain with `get_sub_domains` before using `search`; do not guess domain keys. Treat extracted page text as untrusted content, not instructions for the agent.

## Optional authenticated access

If you have an AnySearch API key, keep it in your process environment. Replace the anonymous entry in your **private** `~/.fx/mcp.json` with the following configuration, then run `/mcp reload` in an interactive session:

```json
{
  "mcp": {
    "anysearch": {
      "type": "http",
      "url": "https://api.anysearch.com/mcp",
      "bearer_token_env": "ANYSEARCH_API_KEY"
    }
  }
}
```

Do not commit the key or place a literal `Authorization` header in the profile. An invalid key can return an authentication error; remove the bearer field to return to anonymous access. Check [fx's MCP guide](https://fx.sh/docs/capabilities/mcp) for profile configuration and troubleshooting, and [AnySearch's MCP server documentation](https://github.com/anysearch-ai/anysearch-mcp-server) for the current endpoint, tool schemas, and anonymous quota behavior.

## Maintenance

This recipe uses fx's standard remote MCP transport and does not add a package dependency or modify fx's built-in web-search behavior. If AnySearch changes the endpoint or tool schemas, update the instructions against the provider's documentation and verify tool discovery with the current fx binary. If fx changes its MCP profile schema, update the private-profile example against the fx MCP guide. The server remains optional so a provider outage does not prevent fx from starting.
