///|
test "provider requests share API body and authorization rules" {
  for kind in ["openai-responses", "openai-compatible", "anthropic-messages"] {
    let provider = test_selected_provider(
      "provider = \"test\"\n[providers.test]\nkind = \"\{kind}\"\n[providers.test.config]\nmodel = \"model\"\nendpoint = \"http://localhost/test\"\nreasoning_effort = \"high\"\napi_key_env = \"TEST_KEY\"\nmax_tokens = 2048",
    )
    guard provider.prepare_request(test_prompt("data")) is Http(request) else {
      fail("expected HTTP request")
    }
    let request = request.transport()
    assert_eq(request.auth.env, "TEST_KEY")
    if kind == "openai-responses" {
      assert_eq(request.body, {
        "model": "model",
        "store": false,
        "instructions": "instructions",
        "input": "data",
        "max_output_tokens": 2048,
        "reasoning": { "effort": "high" },
      })
    } else if kind == "anthropic-messages" {
      assert_eq(request.auth.header, "x-api-key")
      assert_eq(request.auth.prefix, "")
      assert_eq(request.headers.get("anthropic-version"), Some("2023-06-01"))
      assert_eq(request.body, {
        "model": "model",
        "system": "instructions",
        "messages": [{ "role": "user", "content": "data" }],
        "max_tokens": 2048,
        "output_config": { "effort": "high" },
      })
    } else {
      assert_eq(request.body, {
        "model": "model",
        "messages": [
          { "role": "system", "content": "instructions" },
          { "role": "user", "content": "data" },
        ],
        "max_tokens": 2048,
        "reasoning_effort": "high",
      })
    }
    if kind != "anthropic-messages" {
      assert_eq(request.auth.header, "authorization")
      assert_eq(request.auth.prefix, "Bearer ")
    }
  }
}

///|
test "empty reasoning effort is omitted" {
  let provider = test_selected_provider(
    "provider = \"openai\"\n[providers.openai]\nkind = \"openai-responses\"\n[providers.openai.config]\nreasoning_effort = \"\"",
  )
  guard provider.prepare_request(test_prompt("data")) is Http(request) else {
    fail("expected HTTP")
  }
  let request = request.transport()
  assert_true(request.body is { "reasoning"? : None, .. })
}
