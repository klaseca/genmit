<p align="center">
  <img src="./assets/logo.png" alt="genmit" height="150px" />
</p>

# genmit

genmit generates a commit message from the changes already staged in Git.
It never stages files and never creates the commit: the CLI prints a message for
you to review, while the VS Code extension places it in the Source Control input.

The default provider is Codex CLI, so an existing ChatGPT/Codex login is enough
to get started. OpenAI Responses, OpenAI-compatible Chat Completions, Anthropic
Messages, and custom command-line harnesses are also supported.

## Quick start

Install the CLI from Mooncakes with an up-to-date MoonBit toolchain:

```shell
moon install klaseca/genmit
```

Install Codex CLI, sign in once, then stage the changes you want described:

```shell
codex login
git add <files>
genmit
```

`genmit` prints the generated message to standard output. Review it and create
the commit normally. The default Codex harness runs `codex exec` in its
read-only sandbox and reuses the existing login. It ignores the Codex user
configuration, rules, and project instructions, and disables shell access,
hooks, apps, subagents, and web search. Configure its model and reasoning
effort through genmit instead.

## CLI

Running `genmit` without a command is the same as `genmit generate`.

```text
genmit [options]
genmit generate [options] [--json]
genmit prompt [options]
genmit providers [options] [--json]
```

Commands:

- `generate` generates and prints a commit message.
- `prompt` prints the direct prompt without contacting the provider.
- `providers` lists the providers available in the active configuration and
  marks the selected one with `*`.

`providers` only reads configuration and does not require a Git repository.

Options:

- `-C, --cwd <directory>` selects the Git repository and the base for a
  relative config path.
- `-c, --config <file>` uses one TOML file instead of automatic user-config
  discovery.
- `-p, --provider <name>` selects a configured provider without changing the
  config file.
- `--json` returns machine-readable output from `generate` or `providers`.
- `-V, --version` prints the version.
- `-h, --help` prints help. Use `genmit <command> --help` for command-specific
  options.

The `--cwd`, `--config`, and `--provider` options may appear before or after a
command. For example, these are equivalent:

```shell
genmit --provider openai generate
genmit generate --provider openai
```

Only staged changes are used. Unstaged and untracked content is not collected
by genmit.

`genmit generate --json` returns a stable result for scripts and editor
integrations:

```json
{
  "protocol_version": 1,
  "message": "feat: improve the CLI",
  "provider": "codex",
  "files": ["src/cli.mbt"]
}
```

## Configuration

Without `--config`, genmit starts with built-in defaults and then looks for one
user config:

1. `$GENMIT_HOME/config.toml`, when `GENMIT_HOME` is set;
2. otherwise `<home>/.config/genmit/config.toml`.

On Windows, `USERPROFILE` is used as the home directory, with `HOME` as a
fallback. If no file exists, the built-in configuration is ready to use with
Codex CLI.

Passing `--config <file>` disables discovery and applies that file over the
built-in defaults. Configuration files are not combined with each other.
Relative paths are resolved from `--cwd`, or from the current directory when
`--cwd` is omitted.

A small user config can contain only the settings being changed:

```toml
provider = "codex"
language = "en"
style = "conventional"
include_body = true
max_subject_length = 72

[generation]
max_provider_calls = 32
timeout_ms = 600000

[prompt]
extra = ""
```

The main generation settings are:

- `language`: the language requested for the message;
- `style`: `conventional`, `plain`, or `gitmoji`;
- `include_body`: whether a body is allowed after the subject;
- `max_subject_length`: subject limit from 20 to 200 characters;
- `prompt.extra`: additional instructions;
- `generation.max_provider_calls` and `generation.timeout_ms`: whole-generation
  safety limits.

The built-in providers are:

| Name        | Kind                 | Connection                        |
| ----------- | -------------------- | --------------------------------- |
| `codex`     | `codex`              | Codex CLI with the existing login |
| `openai`    | `openai-responses`   | OpenAI Responses API              |
| `anthropic` | `anthropic-messages` | Anthropic Messages API            |

The built-in `codex` and `openai` providers use `gpt-5.6-luna`; `anthropic`
uses `claude-sonnet-5`. Their default reasoning effort is `low`. A user config
may override individual settings without repeating the whole built-in provider:

```toml
[providers.codex.config]
model = "gpt-5.6-luna"
reasoning_effort = "low"
```

To use the built-in OpenAI provider, select it and expose the API key to the
process:

```toml
provider = "openai"
```

```powershell
$env:OPENAI_API_KEY = "..."
genmit
```

New API providers require an explicit `kind`, `endpoint`, and `model`. Supported
API kinds are `openai-responses`, `openai-compatible`, and
`anthropic-messages`. Custom command-line integrations are defined as reusable
`harnesses`, then referenced by name from a provider. See
[`genmit.example.toml`](https://github.com/klaseca/genmit/blob/main/genmit.example.toml) for both forms.

For a harness, `args` are followed by the arguments produced by configured
parameters and then by `tail_args`. A parameter is included when its provider
value is non-empty, and `${value}` is replaced with that value. The prepared
prompt is passed through standard input. Harnesses run in the repository root,
must remain in the foreground, and should clean up their own child processes
when cancelled.

API keys are read from the environment variable named by `api_key_env`; the key
itself should not be written to TOML. `reasoning_effort` is optional and its
valid values depend on the selected model.

## Large staged changes

Small staged diffs use one provider request. Larger diffs are split without
dropping content, summarized, and reduced before the final commit message is
generated. The default limits are 32 provider calls and 600000 milliseconds for
one generation. If the work cannot fit within those limits, genmit fails instead
of silently omitting part of the diff.

## VS Code extension

The extension in [`apps/vscode-extension`](https://github.com/klaseca/genmit/tree/main/apps/vscode-extension) bundles the JavaScript build of
the MoonBit runtime, so the standalone CLI is not required. It adds a Source
Control action that generates a message for the selected repository and writes
it to the commit input. Provider selection is available from the Source Control
overflow menu and the Command Palette.

See the [extension README](https://github.com/klaseca/genmit/blob/main/apps/vscode-extension/README.md) for installation, usage,
configuration, cancellation, and troubleshooting.

## Security

Review `git diff --cached` before generation. A staged diff can contain secrets
and is sent to the selected network provider. A custom harness runs in the
repository root with the permissions of its executable. The staged-only rule
limits what genmit collects; it is not a filesystem sandbox for an external
program. The built-in Codex harness requests Codex's read-only sandbox.
It also ignores Codex user configuration, rules, and project instructions and
disables shell access, hooks, apps, subagents, and web search. This keeps the
built-in harness focused on the prompt prepared by genmit. A custom harness can
opt into normal Codex behavior when repository-aware generation is desired.

## Development

Build and test the MoonBit module:

```shell
moon check
moon test
moon build src --release
moon build src --target wasm
```

Install the CLI from the current checkout:

```shell
moon install ./src
```

Build and test the extension:

```shell
cd apps/vscode-extension
npm install
npm test
npm run package
```

The extension build compiles `src/js_runtime` to JavaScript and bundles it with
esbuild. For package boundaries and runtime details, see
[`docs/architecture.md`](https://github.com/klaseca/genmit/blob/main/docs/architecture.md).
