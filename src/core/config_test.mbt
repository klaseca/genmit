///|
fn test_config(data : String) -> @core.Config raise @core.GenmitError {
  @core.Config::from_toml(data)
}

///|
fn test_selected_provider(
  data : String,
) -> @core.SelectedProvider raise @core.GenmitError {
  test_config(data).select_provider()
}

///|
fn test_prompt(data : String) -> @core.Prompt {
  { instructions: "instructions", data, }
}

///|
test "empty TOML resolves to the built-in defaults" {
  assert_eq(test_config(""), @core.default_config())
}

///|
test "TOML partially overrides a built-in API provider" {
  guard test_config("")
    .select_provider(provider="openai")
    .prepare_request(test_prompt("prompt"))
    is Http(default_request) else {
    fail("built-in OpenAI provider did not produce an HTTP request")
  }
  let default_request = default_request.transport()
  guard default_request.body is { "model": String(default_model), .. } else {
    fail("built-in OpenAI request did not contain a model")
  }

  let provider = test_selected_provider(
    "provider = \"openai\"\n[providers.openai.config]\nmax_tokens = 2048",
  )

  guard provider.prepare_request(test_prompt("prompt")) is Http(request) else {
    fail("built-in OpenAI provider did not produce an HTTP request")
  }
  let request = request.transport()
  assert_eq(request.endpoint, default_request.endpoint)
  assert_eq(request.auth.env, default_request.auth.env)
  assert_true(
    request.body is { "model": String(model), "max_output_tokens": 2048, .. } &&
    model == default_model,
  )
}

///|
test "TOML adds reusable harnesses and concrete providers" {
  let input =
    #|provider = "local"
    #|language = "ru"
    #|style = "plain"
    #|include_body = false
    #|max_subject_length = 60
    #|
    #|[prompt]
    #|extra = "Use the project vocabulary."
    #|
    #|[harnesses.pi]
    #|executable = "pi"
    #|args = ["--print"]
    #|
    #|[harnesses.pi.parameters.model]
    #|required = true
    #|args = ["--model", "${value}"]
    #|
    #|[providers.local]
    #|kind = "pi"
    #|
    #|[providers.local.config]
    #|model = "local-model"
    #|

  let config = test_config(input)
  let provider = config.select_provider()

  assert_eq(config.provider, "local")
  assert_eq(config.language, "ru")
  assert_eq(config.style, Plain)
  assert_false(config.include_body)
  assert_eq(config.max_subject_length, 60)

  let prompt = test_prompt("prompt")

  guard provider.prepare_request(prompt) is Process(executable~, args~, input~) else {
    fail("local provider did not produce a pi process request")
  }

  assert_eq(input, prompt.to_text())

  assert_eq(executable, "pi")
  assert_eq(args, ["--print", "--model", "local-model"])
}

///|
test "new API providers require their own endpoint and model" {
  for kind in ["openai-responses", "openai-compatible", "anthropic-messages"] {
    for
      (field, config) in [
        ("endpoint", "model = \"model\""),
        ("model", "endpoint = \"http://localhost/test\""),
      ] {
      let input = "[providers.custom]\nkind = \"\{kind}\"\n[providers.custom.config]\n\{config}"
      try test_config(input) catch {
        GenmitError(message) =>
          assert_eq(
            message,
            "providers.custom.config.\{field} must not be empty",
          )
      } noraise {
        _ => fail("expected a new API provider to require its own \{field}")
      }
    }
  }
}

///|
test "providers sharing an API kind keep independent settings" {
  for kind in ["openai-responses", "openai-compatible", "anthropic-messages"] {
    let input =
      $|[providers.first]
      $|kind = "\{kind}"
      $|[providers.first.config]
      $|endpoint = "http://localhost/first"
      $|model = "first-model"
      $|reasoning_effort = "high"
      $|api_key_env = "FIRST_KEY"
      $|max_tokens = 2048
      $|
      $|[providers.second]
      $|kind = "\{kind}"
      $|[providers.second.config]
      $|endpoint = "http://localhost/second"
      $|model = "second-model"

    let config = test_config(input)
    let prompt = test_prompt("prompt")
    guard config.select_provider(provider="first").prepare_request(prompt)
      is Http(first) else {
      fail("first provider did not produce an HTTP request")
    }
    let first = first.transport()
    assert_eq(first.endpoint, "http://localhost/first")
    assert_eq(first.auth.env, "FIRST_KEY")
    assert_true(first.body is { "model": "first-model", .. })

    guard config.select_provider(provider="second").prepare_request(prompt)
      is Http(second) else {
      fail("second provider did not produce an HTTP request")
    }
    let second = second.transport()
    assert_eq(second.endpoint, "http://localhost/second")
    assert_eq(second.auth.env, "")
    assert_true(
      second.body
      is {
        "model": "second-model",
        "reasoning"? : None,
        "reasoning_effort"? : None,
        "output_config"? : None,
        ..
      },
    )
    match kind {
      "openai-responses" => {
        assert_true(first.body is { "max_output_tokens": 2048, .. })
        assert_true(second.body is { "max_output_tokens": 1024, .. })
      }
      _ => {
        assert_true(first.body is { "max_tokens": 2048, .. })
        assert_true(second.body is { "max_tokens": 1024, .. })
      }
    }
  }
}

///|
test "changing a built-in provider kind requires a new API configuration" {
  for
    (name, kind) in [
      ("openai", "anthropic-messages"),
      ("anthropic", "openai-responses"),
      ("codex", "openai-responses"),
    ] {
    let input = "[providers.\{name}]\nkind = \"\{kind}\"\n[providers.\{name}.config]\nendpoint = \"http://localhost/test\""
    try test_config(input) catch {
      GenmitError(message) =>
        assert_eq(message, "providers.\{name}.config.model must not be empty")
    } noraise {
      _ => fail("expected a changed API kind to require its own model")
    }
  }
}

///|
test "TOML rejects an unknown selected provider" {
  try test_config("provider = \"missing\"") catch {
    GenmitError(message) => assert_true(message.contains("has no matching"))
  } noraise {
    _ => fail("expected config validation to fail")
  }
}

///|
test "TOML rejects integers that overflow MoonBit Int" {
  try test_config("max_subject_length = 4294967368") catch {
    GenmitError(message) => assert_true(message.contains("out of range"))
  } noraise {
    _ => fail("expected integer range validation to fail")
  }
}

///|
test "TOML does not coerce floating-point values to integers" {
  try test_config("max_subject_length = 40.5") catch {
    GenmitError(message) => assert_true(message.contains("max_subject_length"))
  } noraise {
    _ => fail("expected config validation to fail")
  }
}

///|
test "config requires declared harness parameters" {
  let input =
    #|[providers.codex.config]
    #|model = ""
    #|

  try test_config(input) catch {
    GenmitError(message) =>
      assert_eq(message, "providers.codex.config.model must not be empty")
  } noraise {
    _ => fail("expected config validation to fail")
  }
}

///|
test "config validates the common API token limit" {
  for kind in ["openai-responses", "openai-compatible", "anthropic-messages"] {
    let input = "provider = \"test\"\n[providers.test]\nkind = \"\{kind}\"\n[providers.test.config]\nendpoint = \"http://localhost/test\"\nmodel = \"model\"\nmax_tokens = 0"
    try test_config(input) catch {
      GenmitError(message) =>
        assert_eq(message, "providers.test.config.max_tokens must be positive")
    } noraise {
      _ => fail("expected config validation to fail")
    }
  }
}

///|
test "config validates whole-generation limits" {
  for field in ["max_provider_calls", "timeout_ms"] {
    try test_config("[generation]\n\{field} = 0") catch {
      GenmitError(message) =>
        assert_eq(message, "generation.\{field} must be positive")
    } noraise {
      _ => fail("expected config validation to fail")
    }
  }
}

///|
test "config validates providers that are not selected" {
  let input =
    #|[providers.unused]
    #|kind = "openai-compatible"
    #|
    #|[providers.unused.config]
    #|endpoint = "http://localhost/v1/chat/completions"
    #|model = ""
    #|

  try test_config(input) catch {
    GenmitError(message) =>
      assert_eq(message, "providers.unused.config.model must not be empty")
  } noraise {
    _ => fail("expected config validation to fail")
  }
}

///|
test "harness names cannot shadow built-in API kinds" {
  let input =
    #|[harnesses.openai-responses]
    #|executable = "custom"
    #|

  try test_config(input) catch {
    GenmitError(message) => assert_true(message.contains("conflicts"))
  } noraise {
    _ => fail("expected config validation to fail")
  }
}

///|
test "TOML ignores unknown keys" {
  for
    source in [
      "max_dif_chars = 6000", "[providers.codex]\nunused = true", "[providers.openai]\nkind = \"openai-responses\"\n[providers.openai.config]\nreasoning_efort = \"high\"",
      "[harnesses.codex.parameters.model]\nrequire = true", "unused_float = 0.5",
      "unused_date = 2026-09-09",
    ] {
    test_config(source) |> ignore
  }
}
