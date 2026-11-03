# provider-agent

`provider-agent` runs persistent coding workers through Claude Code and
Anthropic-compatible provider endpoints. One shared Bash core implements the
worker model; per-provider profiles and plugins adapt it to each vendor.

A worker keeps one Claude session, working directory, and model across `start`
and later `send` calls. A headless turn runs synchronously, or as a detached
operation that the worker ID recovers. Prompts, durable reports, raw Claude
responses, and stderr stay on disk.

## Providers

| Plugin | Provider | CLI | Profile | Docs |
| --- | --- | --- | --- | --- |
| `glm-agent` | Z.ai GLM | `glm/glm-agent`, `glm/scripts/glm-dispatch` | `core/providers/glm.sh` | [glm/README.md](glm/README.md) |
| `qwen-agent` | Alibaba Cloud Model Studio Qwen (Token Plan) | `qwen/qwen-agent`, `qwen/scripts/qwen-dispatch` | `core/providers/qwen.sh` | [qwen/README.md](qwen/README.md) |

Both plugins expose the same bridge agents (`<plugin>:explorer`,
`<plugin>:general-purpose`), the same dispatch skill, and the same worker
contract: every turn writes a durable report that ends in `STATUS: DONE` or
`STATUS: BLOCKED`.

## Installation

Add this repository as a marketplace and install one or both plugins:

```bash
claude plugin marketplace add powdream-org/provider-agent
claude plugin install glm-agent@provider-agent --scope user
claude plugin install qwen-agent@provider-agent --scope user
```

Each plugin is self-contained for its entry scripts, bridge agents, and
skills; the shared engine lives in `core/` inside the same checkout.

## Repository layout

```text
core/
  agent-core.sh      Shared engine: worker lifecycle, turn execution,
                     result contract, cleanup, auth accounts, embedded help
  providers/         Provider profiles (glm.sh, qwen.sh)
  dispatch/          Shared dispatch script modules, sourced by each
                     provider's qwen-dispatch-style entry
  system-prompt.md   Worker execution and durable-result contract
  prompts/           Role prompts (explorer, general-purpose)
glm/                glm-agent plugin: entry scripts, agents, skills, README
qwen/               qwen-agent plugin: entry scripts, agents, skills, README
scripts/            Release tooling (bump-version.sh)
tests/              Hermetic CLI, plugin, and dispatch suites
```

## Adding a provider

A provider is a profile file plus a thin plugin directory:

1. Copy `core/providers/qwen.sh` and fill in the profile contract documented
   at the top of `core/agent-core.sh`: identity, state home, user-facing
   environment variable names, default endpoint and model mappings, extra
   Claude environment, and the quota backend.
2. Override `extract_provider_code`, `classify_error_kind`, and
   `provider_response_is_error` in the profile when the provider's error
   shapes differ from the defaults.
3. Add a plugin directory with an entry script that sources the profile and
   the core, a `scripts/<id>-dispatch` entry that sources `core/dispatch/`,
   bridge agents, the dispatch skill, and a `plugin.json`.
4. Register the plugin in `.claude-plugin/marketplace.json`.

## Requirements

- Bash 3.2 or newer
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) available as `claude`
- `jq`
- `curl` 7.55 or newer, for `glm-agent quota`
- A provider API key
- macOS or a Unix-like environment

## Development

```bash
bash tests/test_glm_agent.sh
bash tests/test_plugin.sh
bash tests/test_dispatch.sh
```

Static checks and plugin validation are documented in
[AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE) © 2026 Heejoon Kang
