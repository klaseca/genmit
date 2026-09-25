# Architecture

The repository has one MoonBit module with two frontends around one shared
generation workflow:

```text
                      src/core
               (configuration and rules)
                         |
                      src/host
          (Git workflow, HTTP, provider execution)
                    /           \
            src/runtime       src/js_runtime
           (native process)   (async JS boundary)
                 |                   |
             CLI package    apps/vscode-extension
```

`src/core` contains the portable data model and pure rules: TOML config resolution,
lossless diff splitting, prompt construction, provider request construction,
response extraction, and message normalization.

`src/host` contains the end-to-end workflow shared by native and JavaScript
frontends. It gathers staged Git state, builds the prompt, executes either a
harness or a supported HTTP API, and returns a normalized `GenerationResult`.
It asks its caller for one capability when needed: run a process and return its
exit code, stdout, and stderr. HTTP remains in MoonBit because the async HTTP
package has both native and JavaScript implementations.

`src/runtime` supplies that process capability with MoonBit's native async
process API. It also owns CLI-only filesystem configuration discovery. The CLI
calls this runtime directly.

`src/js_runtime` exports the asynchronous ESM function `generate` and the
synchronous `list_providers` function. The latter returns only provider names,
kinds, and the selected default, using the same configuration parser as
generation. The VS Code extension sends generation the repository
root, TOML text, an optional named provider selection, an
`AbortSignal`, and a process callback. The callback is the only operating-system
boundary implemented in TypeScript. Process requests and results cross it as
plain JavaScript objects assembled by the JS FFI layer, without an intermediate
JSON protocol. Consequently,
TypeScript does not model Git context, prepared provider requests, HTTP payloads,
or resolved provider configuration.

The extension still reads its selected config file because that choice belongs
to VS Code. Harness executables are taken exclusively from that configuration;
the extension has no harness-specific executable lookup. The MoonBit runtime
owns everything from Git collection through the final normalized message. The
extension only chooses a repository, calls `generate`, and safely applies its
result to the SCM input.

## Provider, harness, and API boundary

Selection is data-driven through named `[providers.<name>]` tables. Every
provider has one `kind`: it names either a reusable `[harnesses.<kind>]` command
template or an HTTP API implemented by genmit. Harness providers contain only
the parameter values declared by their template; API providers share one
normalized configuration that each HTTP implementation maps to its protocol.
Built-in harness templates live in their own map. Built-in API defaults live
directly in the concrete `openai` and `anthropic` providers, so there is no
second API-default map to synchronize. The default configuration also creates
the ready `codex` provider. User TOML may override selected fields of these
providers by name while retaining their kind, or add another provider explicitly.
A new API provider must specify its own endpoint and model; it does not inherit
settings from another provider sharing its API kind. Changing a built-in
provider's kind also requires a new configuration.

Provider instructions and untrusted Git data remain separate inside the core.
Responses uses its `instructions` field, Chat Completions uses a system message,
and Anthropic Messages uses its top-level `system` field. Command-line harnesses
receive a plain text form because their stdin protocols do not provide
message roles.

Provider selection returns a `SelectedProvider` containing only its name and
request preparation behavior. The complete `Config` remains separate; request
sizing and every provider call reuse the same selected provider.

Each built-in HTTP API implements the `HttpRequest` trait in its own file. The
implementation owns both request construction and response extraction; the host
only executes the shared `HttpTransport` data and delegates interpretation of
the response back to the same request object.

The built-in API kinds are:

- `openai-responses`: OpenAI Responses API;
- `openai-compatible`: Chat Completions-compatible endpoints;
- `anthropic-messages`: Anthropic Messages API.

The default `codex` harness invokes `codex exec` in a read-only sandbox and
reuses its existing authentication. It ignores Codex user configuration,
rules, and project instructions and disables shell access, hooks, apps,
subagents, and web search so the built-in path is driven by genmit's prepared
prompt rather than those Codex customization layers.
Additional CLI tools can be described as harnesses without adding transport
code. HTTP protocols are implemented in MoonBit rather than described as
arbitrary config templates. Harness processes run in the repository root
because user-configured repository-aware CLIs may need that context. The
staged-only rule describes data collected by genmit, not a filesystem security
boundary for arbitrary user-configured executables.

## Configuration and secrets

Without `--config`, the CLI loads `$GENMIT_HOME/config.toml`, or
`.config/genmit/config.toml` under the user's home directory when `GENMIT_HOME`
is unset (`USERPROFILE` on Windows, falling back to `HOME`). With `--config`,
automatic discovery is skipped. A loaded file customizes only the built-in
defaults; configurations are never composed with one another. Provider listing
does not collect Git state and can load configuration outside a repository;
relative config paths are resolved from the command's working directory.

The extension has one setting, `genmit.configPath`. An empty path uses the same
user-config discovery as the CLI; an explicit path selects only that TOML file.
Typed defaults, parsing, and validation remain in MoonBit. Providers and
harnesses are edited directly in TOML; the extension has no configuration editor
or API-specific configuration models.

The provider picker loads names dynamically from the current configuration.
It stores only the selected provider name per repository and config path in the
extension's user state, never a second configuration. Generation checks that a
saved name still exists and otherwise uses the config's default provider. The
picker can clear the saved choice to follow the default again. The extension
never writes external TOML and does not infer a provider's kind from its name.

Every TOML source is resolved through `Config::Config`. The constructor
validates the complete configuration, including providers that are not selected,
and keeps the provider collections private. Later provider selection looks up
already validated data and does not repeat configuration validation.

API keys are never configuration values. `api_key_env` names the environment
variable from which the MoonBit HTTP implementation reads its credential.
Unknown TOML keys are ignored; known fields remain type-checked.

## Cancellation and resource limits

Each provider or Git process has a 180-second deadline. VS Code cancellation is
passed through the JS runtime to process execution, and a newer generation
cancels an older one for the same repository. A result only replaces an
unchanged commit input; if the user edited it, the result opens separately.

The VS Code process adapter terminates the command's process group on Unix and
uses `taskkill /PID <pid> /T /F` on Windows. Cancellation, operation timeouts,
and output-limit failures wait for the termination command and the direct
command's `close` event before rejecting the process callback. Harnesses should
remain in the foreground; the adapter does not contain processes that
deliberately daemonize or leave the command's process group.

The native runtime relies on `moonbitlang/async` process cancellation: it first
asks the directly spawned harness to terminate and forcefully stops that process
after the library's grace period. It does not inspect or traverse the operating
system process tree. Native harnesses are responsible for terminating their own
children and must not daemonize them.

The `[generation]` configuration also sets a whole-generation deadline and a
provider-call budget. The initial lossless chunk count is checked before the
first provider call, and every summary, reduction, and final request consumes
the same budget. Exceeding either limit fails generation instead of omitting
staged content.

Git stdout is limited to 16 MiB, provider stdout and HTTP bodies to 4 MiB, and
process stderr to 1 MiB. Staged diffs are never sampled. A large diff is split
losslessly at file, line, or Unicode-character boundaries. Continuation chunks
carry their file and hunk context, and the limit is checked against the prepared
provider request rather than only the raw diff. Chunks are summarized through
the selected provider and recursively reduced before the final request. Any
failed or invalid intermediate response fails the generation instead of
silently omitting a chunk. The normalized result is rejected when its subject
exceeds `max_subject_length`, or when it contains a body while `include_body`
is false. OpenAI Responses requests set `store` to `false`. HTTP API configs
also provide explicit output-token limits using their protocol-native request
fields.

## Development checks

Run `moon check --warn-list +73` and `moon test` for the native CLI, and use
`moon build --target wasm` to keep the portable target buildable. In
`apps/vscode-extension`, run `npm test` and `npm run build` for the JavaScript runtime and
extension. Run `moon info` and `moon fmt` after MoonBit changes, then review
generated interface diffs.
