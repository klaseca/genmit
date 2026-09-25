///|
test "CLI parses global selection and command-specific output options" {
  let options = parse_cli([
    "--cwd", "repository", "--config", "release.toml", "--provider", "openai", "generate",
    "--json",
  ])
  assert_eq(options.action, Generate)
  assert_eq(options.cwd, "repository")
  assert_eq(options.config_path, Some("release.toml"))
  assert_eq(options.provider, Some("openai"))
  assert_true(options.json)

  let providers = parse_cli(["providers", "--json"])
  assert_eq(providers.action, Providers)
  assert_true(providers.json)

  let options_after_command = parse_cli([
    "generate", "--provider", "openai", "--config", "release.toml",
  ])
  assert_eq(options_after_command.provider, Some("openai"))
  assert_eq(options_after_command.config_path, Some("release.toml"))
}

///|
test "CLI uses plain generation by default" {
  let options = parse_cli([])
  assert_eq(options.action, Generate)
  assert_false(options.json)
}

///|
test "CLI rejects missing values and unsupported option combinations" {
  for
    args in [
      ["--provider"],
      ["--config"],
      ["--json"],
      ["prompt", "--json"],
      ["help"],
    ] {
    try parse_cli(args) catch {
      GenmitError(_) => ()
    } noraise {
      _ => fail("expected invalid CLI arguments to be rejected")
    }
  }
}

///|
test "CLI help exposes one help mechanism" {
  let help = cli_command().render_help()
  assert_true(help.contains("-h, --help"))
  assert_false(help.contains("help       Print help"))
  assert_true(help.contains("generate   Generate a commit message"))
}

///|
test "CLI provider output marks the selected provider in text and JSON" {
  let config = @core.default_config()
  let selected = config.select_provider(provider="openai")

  let text = provider_list_output(config, selected, false)
  assert_true(text.contains("* openai (openai-responses)\n"))
  assert_true(text.contains("  codex (codex)\n"))

  guard @json.parse(provider_list_output(config, selected, true))
    is [
      { "name": "codex", "selected": false, .. },
      { "name": "openai", "selected": true, .. },
      { "name": "anthropic", "selected": false, .. },
    ] else {
    fail("expected a JSON provider list with one selected provider")
  }
}

///|
test "CLI generation output is plain text or structured JSON" {
  let result : @core.GenerationResult = {
    protocol_version: 1,
    message: "feat: add CLI",
    provider: "codex",
    files: ["src/main.mbt"],
  }

  assert_eq(generation_output(result, false), "feat: add CLI\n")
  guard @json.parse(generation_output(result, true))
    is {
      "protocol_version": 1,
      "message": "feat: add CLI",
      "provider": "codex",
      "files": ["src/main.mbt"],
      ..
    } else {
    fail("expected a structured generation result")
  }
}
