///|
test "CLI parses global selection and command-specific output options" {
  let options = parse_cli([
    "--cwd", "repository", "--config", "release.toml", "--provider", "openai", "--verbose",
    "generate", "--json",
  ])
  assert_eq(options.action, Generate)
  assert_eq(options.cwd, "repository")
  assert_eq(options.config_path, Some("release.toml"))
  assert_eq(options.provider, Some("openai"))
  assert_true(options.json)
  assert_true(options.verbose)

  let providers = parse_cli(["providers", "--json"])
  assert_eq(providers.action, Providers)
  assert_true(providers.json)
  assert_eq(parse_cli(["prompt"]).action, Prompt)

  let options_after_command = parse_cli([
    "generate", "--provider", "openai", "--config", "release.toml", "-v",
  ])
  assert_eq(options_after_command.provider, Some("openai"))
  assert_eq(options_after_command.config_path, Some("release.toml"))
  assert_true(options_after_command.verbose)
}

///|
test "CLI uses plain generation by default" {
  let options = parse_cli([])
  assert_eq(options.action, Generate)
  assert_false(options.json)
  assert_false(options.verbose)
}

///|
test "CLI limits JSON output to generate and providers commands" {
  for args in [["--json"], ["prompt", "--json"]] {
    try parse_cli(args) catch {
      GenmitError(_) => ()
    } noraise {
      _ => fail("expected invalid CLI arguments to be rejected")
    }
  }
}

///|
test "CLI provider output marks the selected provider in text and JSON" {
  let source =
    #|[providers.local]
    #|kind = "openai-compatible"
    #|[providers.local.config]
    #|endpoint = "http://localhost/test"
    #|model = "test-model"
    #|
  let config = @core.Config::from_toml(source)
  let selected = config.select_provider(provider="local")

  let text = provider_list_output(config, selected, false)
  assert_eq(
    text
    .split("\n")
    .filter(line => line.has_prefix("* "))
    .map(line => line.to_owned())
    .to_array(),
    ["* local (openai-compatible)"],
  )

  guard @json.parse(provider_list_output(config, selected, true))
    is Array(providers) else {
    fail("expected a JSON provider list")
  }
  assert_eq(providers.length(), config.provider_kinds().length())
  let selected_names = providers.filter_map(value => {
    match value {
      { "name": String(name), "selected": true, .. } => Some(name)
      _ => None
    }
  })
  assert_eq(selected_names, ["local"])
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
