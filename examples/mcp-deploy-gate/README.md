# Gate a deploy with an MCP tool

Run a last-seat booking check before deploying the Fieldwork example. The check
replays a synthetic booking scenario using migrations and a rule from a Git
revision.

## Run the check

Install [fx 0.0.18](https://github.com/vercel-labs/fx/releases/tag/v0.0.18) on
Linux with Git, Bash, and jq. Set `AI_GATEWAY_API_KEY` for a tool-capable model
through [AI Gateway](https://fx.sh/docs/getting-started/authentication).

From the fx checkout, create a fresh profile. VibeRaven is an example remote
MCP server.

```sh
FX_HOME=$(mktemp -d)
export FX_HOME FX_PROVIDER=gateway FX_AUTO_UPGRADE=0
cp examples/mcp-deploy-gate/settings.json "$FX_HOME/settings.json"
fx mcp add --no-login viberaven https://viberaven.dev/mcp
fx mcp show viberaven
```

The URL selects Streamable HTTP. [Shared servers](https://fx.sh/docs/capabilities/mcp#idle-and-shared-servers)
are local servers with matching configuration in the same profile.

Clone the fixture and run both revisions.

```sh
fixture=$(mktemp -d)
git clone --no-checkout --depth 2 --branch demo/last-seat-race \
  https://github.com/ohad6k/fieldwork-booking-starter.git "$fixture"
bash examples/mcp-deploy-gate/check.sh "$fixture" e576ec5
bash examples/mcp-deploy-gate/check.sh "$fixture" 499d484
```

| Revision | Tool status | Broken orders | Gate exit |
| --- | --- | --- | --- |
| `e576ec5` | `broken` | 12 of 20 | 1 |
| `499d484` | `no_break` | 0 of 20 | 0 |

The script asks `fx ask` to run one shell command allowed by the profile.
`fx mcp call` writes the tool's JSON to a file from inside that shell call.
The gate reads that file and passes only on a complete `no_break` result with
zero broken orders. A missing or incomplete result also blocks deployment.

## Run before deployment

Add this step before deploy in a GitHub Actions job. It assumes the runner has
fx 0.0.18 on its path and the fx and Fieldwork checkouts in `fx/` and
`fieldwork/`. The check uses the Fieldwork checkout's `HEAD`.

```yaml
- name: Check the last-seat rule
  env:
    AI_GATEWAY_API_KEY: ${{ secrets.AI_GATEWAY_API_KEY }}
    FX_HOME: ${{ runner.temp }}/fx-fieldwork
    FX_PROVIDER: gateway
    FX_AUTO_UPGRADE: "0"
  run: |
    mkdir -p "$FX_HOME"
    cp fx/examples/mcp-deploy-gate/settings.json "$FX_HOME/settings.json"
    fx mcp add --no-login viberaven https://viberaven.dev/mcp
    bash fx/examples/mcp-deploy-gate/check.sh fieldwork
```
