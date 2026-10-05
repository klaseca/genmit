# Architecture

The CLI and VS Code extension share one MoonBit generation workflow.

```text
                      src/core
               (configuration and rules)
                         |
                      src/host
             (Git and provider workflow)
                    /           \
            src/runtime       src/js_runtime
            (native CLI)     (JavaScript bridge)
                 |                   |
             CLI package    apps/vscode-extension
```

## Responsibilities

- `src/core` owns configuration, diff splitting, prompts, provider request and
  response formats, and message validation. These rules are independent of the
  frontend.
- `src/host` collects staged Git changes, calls the selected provider, and
  returns the generated message. HTTP execution stays in MoonBit; process
  execution is supplied by the runtime.
- `src/runtime` provides native process execution and CLI configuration loading.
- `src/js_runtime` exposes the shared workflow to JavaScript and forwards
  cancellation and progress across that boundary.
- `apps/vscode-extension` chooses the repository and config file, runs processes,
  displays progress, and applies the result to Source Control.

The extension does not duplicate provider protocols or generation rules. This
keeps CLI and editor behavior consistent while letting each frontend own its UI
and operating-system integration.

## Providers and configuration

A named provider selects either an HTTP API or a command-line harness. Harnesses
are configured command templates; adding another CLI tool does not require a
new transport implementation. HTTP protocols are implemented in MoonBit.

The core parses and validates TOML over built-in defaults. Each frontend chooses
which file to load. The extension stores provider selections separately and
never rewrites the user's configuration. API keys come from environment
variables rather than TOML.

Provider instructions and Git content are kept separate where the API supports
message roles. The built-in Codex harness uses a read-only sandbox and disables
Codex customization and tools so it follows genmit's prepared prompt. Custom
harnesses execute with their own permissions; staged-only collection does not
restrict what an external executable can access.

See the [configuration guide](../README.md#configuration) for settings and
examples.

## Generation workflow

The host collects staged changes and prepares a request for the selected
provider. Large diffs are split without discarding content, summarized, and
reduced before the final message request. Request sizing includes the prepared
prompt, not just the raw diff. A failed intermediate request fails the whole
generation.

All provider calls share a call budget and a whole-generation deadline. Process
and HTTP output also have size limits. Exceeding a limit produces an error
instead of silently truncating staged content. The final message is checked
against the configured subject length and body settings.

## Progress and cancellation

The host emits optional progress events for stages, request outcomes, and
timings. Frontends use these events for logs and progress displays. Events do
not contain staged content, generated messages, credentials, or raw provider
diagnostics; detailed errors use the normal error channel.

The CLI writes verbose logs to stderr and results to stdout. The extension uses
VS Code's log channel and updates its status display when progress changes.

Cancellation propagates through the runtime to active operations. Process
adapters wait for cleanup before reporting completion; a cleanup failure must
remain visible even if cancellation or a timeout triggered it. The extension
terminates process groups on Unix and process trees on Windows. The native
runtime terminates the directly spawned process, so native harnesses must clean
up their own children. Harnesses should remain in the foreground.

Starting another generation for the same repository cancels the previous one.
The extension applies a result only if the Source Control input is unchanged;
otherwise it opens the message in a separate editor.

## Development checks

Run `moon check --warn-list +73` and `moon test`, and check the portable target
with `moon build --target wasm`. After MoonBit changes, run `moon info` and
`moon fmt`, then review generated interface diffs.

In `apps/vscode-extension`, run `npm test` and `npm run build` to validate the
JavaScript runtime and extension.
