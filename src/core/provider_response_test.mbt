///|
fn test_http_request(
  kind : String,
) -> &@core.HttpRequest raise @core.GenmitError {
  let provider = test_selected_provider(
    "provider = \"test\"\n[providers.test]\nkind = \"\{kind}\"\n[providers.test.config]\nendpoint = \"http://localhost/test\"\nmodel = \"model\"\napi_key_env = \"\"",
  )
  guard provider.prepare_request(test_prompt("data")) is Http(request) else {
    raise GenmitError("expected HTTP request")
  }
  request
}

///|
fn extract_test_http_response(
  kind : String,
  input : String,
) -> String raise @core.GenmitError {
  test_http_request(kind).extract_response(input)
}

///|
test "Responses API text extraction" {
  let input =
    #|{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"feat: add CLI"}]}]}
    #|
  assert_eq(
    extract_test_http_response("openai-responses", input),
    "feat: add CLI",
  )
}

///|
test "Chat Completions text extraction" {
  let input =
    #|{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"fix: handle empty staging"}}]}
    #|
  assert_eq(
    extract_test_http_response("openai-compatible", input),
    "fix: handle empty staging",
  )
}

///|
test "Anthropic Messages text extraction" {
  let input =
    #|{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"docs: explain providers"}]}
    #|
  assert_eq(
    extract_test_http_response("anthropic-messages", input),
    "docs: explain providers",
  )
}

///|
test "diff chunks preserve content and continuation context" {
  let first = "diff --git a/one b/one\n--- a/one\n+++ b/one\n@@ -1 +1 @@\n+" +
    "🌙".repeat(80) +
    "\n"
  let second = "diff --git a/two b/two\n+second\n"
  let input = first + second
  let chunks = @core.split_diff(input, 50)
  assert_true(chunks.length() > 2)
  assert_eq(chunks.map(chunk => chunk.content).join(""), input)
  for chunk in chunks {
    assert_true(chunk.content.char_length() <= 50)
  }
  let continuations = chunks.filter(chunk => chunk.content.has_prefix("🌙"))
  guard continuations is [continuation, ..] else {
    fail("expected a continuation chunk")
  }
  guard continuation.context is Some(context) else {
    fail("expected continuation context")
  }
  assert_true(context.file.contains("diff --git a/one b/one"))
  assert_eq(context.hunk, Some("@@ -1 +1 @@"))
  assert_true(chunks.last() is Some({ context: None, .. }))
}

///|
test "whole file groups respect the serialized request budget" {
  let first = "diff --git a/one b/one\n+first change\n"
  let second = "diff --git a/two b/two\n+second change\n"
  let escaped = "diff --git a/escaped b/escaped\n+" + "\\\"".repeat(50) + "\n"
  let last = "diff --git a/last b/last\n+last change\n"
  let input = first + second + escaped + last
  for maximum in [100, 160, 1000] {
    let fits = fn(chunk : @core.DiffChunk) {
      Json::string(chunk.content).stringify().char_length() <= maximum
    }
    let chunks = @core.split_diff(input, maximum, fits~)
    assert_eq(chunks.map(chunk => chunk.content).join(""), input)
    for chunk in chunks {
      assert_true(fits(chunk))
    }
    for file in [first, second, last] {
      assert_eq(
        chunks.filter(chunk => chunk.content.contains(file)).length(),
        1,
      )
    }
  }
}

///|
test "all text blocks are retained" {
  assert_eq(
    extract_test_http_response(
      "anthropic-messages",
      (
        #|{"stop_reason":"end_turn","content":[{"type":"text","text":"feat: add export"},{"type":"thinking","thinking":"hidden"},{"type":"text","text":"\n\nSupport JSON."}]}
      ),
    ),
    "feat: add export\n\nSupport JSON.",
  )
  assert_eq(
    extract_test_http_response(
      "openai-responses",
      (
        #|{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"feat:"},{"type":"output_text","text":" export"}]}]}
      ),
    ),
    "feat: export",
  )
}

///|
test "unfinished responses are rejected" {
  for
    pair in [
      (
        "openai-responses", "{\"status\":\"incomplete\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"feat: partial\"}]}]}",
      ),
      (
        "anthropic-messages", "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}",
      ),
      (
        "anthropic-messages", "{\"stop_reason\":\"model_context_window_exceeded\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}",
      ),
      (
        "openai-compatible", "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial\"}}]}",
      ),
      (
        "openai-responses", "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"feat: missing status\"}]}]}",
      ),
      (
        "anthropic-messages", "{\"content\":[{\"type\":\"text\",\"text\":\"missing status\"}]}",
      ),
      (
        "openai-compatible", "{\"choices\":[{\"message\":{\"content\":\"missing status\"}}]}",
      ),
    ] {
    let (kind, response) = pair
    try extract_test_http_response(kind, response) catch {
      GenmitError(_) => ()
    } noraise {
      _ => fail("expected incomplete response error")
    }
  }
}

///|
test "provider error responses retain bounded diagnostics" {
  assert_eq(
    @core.format_provider_error_details("warning\u{001b}[31mred\r"),
    "warning\\u{1b}[31mred\\r",
  )

  try
    extract_test_http_response(
      "openai-responses", "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"invalid model\"}}",
    )
  catch {
    GenmitError(message) =>
      assert_eq(message, "provider returned an error: invalid model")
  } noraise {
    _ => fail("expected provider error")
  }

  try
    extract_test_http_response(
      "openai-responses",
      "{\"error\":{\"message\":\"\{"x".repeat(1100)}\"}}",
    )
  catch {
    GenmitError(message) => {
      assert_true(message.has_prefix("provider returned an error: "))
      assert_true(message.has_suffix("..."))
      assert_false(message.contains("x".repeat(1001)))
    }
  } noraise {
    _ => fail("expected provider error")
  }
}

///|
test "diff chunk size must be positive" {
  try @core.split_diff("change", 0) catch {
    GenmitError(message) => assert_true(message.contains("must be positive"))
  } noraise {
    _ => fail("expected invalid chunk size error")
  }
}
