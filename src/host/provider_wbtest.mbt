///|
async test "bounded reader accepts the limit and rejects overflow" {
  let exact = @io.MemoryReader(writer => writer.write("1234"))
  defer exact.close()
  assert_eq(read_bounded(exact, 4).text(), "1234")
  let excessive = @io.MemoryReader(writer => writer.write("12345"))
  defer excessive.close()
  try read_bounded(excessive, 4) catch {
    @genmit.GenmitError(message) => assert_true(message.contains("byte limit"))
    error => raise error
  } noraise {
    _ => fail("expected byte limit")
  }
}

///|
#cfg(target="native")
async test "native HTTP provider sends a prepared request" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((request, body, conn) => {
        assert_eq(request.path, "/v1/responses")
        assert_eq(request.headers.get("content-type"), Some("application/json"))
        let request_body = body.read_all().text()
        assert_true(
          @json.parse(request_body)
          is {
            "model": "test-model",
            "store": false,
            "instructions": "instructions",
            "input": "staged data",
            ..
          },
        )
        conn.send_response(200, "OK")
        conn.write(
          "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"feat: native HTTP\"}]}]}",
        )
      })
    }

    let source = "provider = \"test\"\n[providers.test]\nkind = \"openai-responses\"\n[providers.test.config]\nendpoint = \"http://127.0.0.1:\{server.addr.port()}/v1/responses\"\nmodel = \"test-model\"\napi_key_env = \"\""
    let provider = @genmit.Config::from_toml(source).select_provider()
    let prompt : @genmit.Prompt = {
      instructions: "instructions",
      data: "staged data",
    }
    guard provider.prepare_request(prompt) is Http(request) else {
      fail("expected an HTTP request")
    }
    assert_eq(post_api(request), "feat: native HTTP")
  }
}

///|
#cfg(target="native")
async test "native HTTP provider reports unsuccessful responses" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, body, conn) => {
        body.read_all() |> ignore
        conn.send_response(429, "Too Many Requests")
        conn.write("rate limited")
      })
    }

    let source = "provider = \"test\"\n[providers.test]\nkind = \"openai-responses\"\n[providers.test.config]\nendpoint = \"http://127.0.0.1:\{server.addr.port()}/v1/responses\"\nmodel = \"test-model\"\napi_key_env = \"\""
    let provider = @genmit.Config::from_toml(source).select_provider()
    let prompt : @genmit.Prompt = {
      instructions: "instructions",
      data: "staged data",
    }
    guard provider.prepare_request(prompt) is Http(request) else {
      fail("expected an HTTP request")
    }
    try post_api(request) catch {
      @genmit.GenmitError(message) =>
        assert_true(message.contains("HTTP 429: rate limited"))
      error => raise error
    } noraise {
      _ => fail("expected HTTP error")
    }
  }
}

///|
async test "provider command diagnostics are bounded" {
  let provider = @genmit.default_config().select_provider()
  let prompt : @genmit.Prompt = { instructions: "instructions", data: "data", }

  try
    call_provider(provider, prompt, ".", _request => {
      code: 1,
      stdout: "",
      stderr: "x".repeat(1100),
    })
  catch {
    @genmit.GenmitError(message) => {
      assert_true(message.has_prefix("command 'codex' exited with code 1: "))
      assert_true(message.has_suffix("..."))
      assert_false(message.contains("x".repeat(1001)))
    }
    error => raise error
  } noraise {
    _ => fail("expected provider command error")
  }
}
