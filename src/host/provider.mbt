///|
async fn read_bounded(reader : &@io.Reader, maximum : Int) -> &@io.Data {
  let buffer = @buffer.Buffer()

  while reader.read_some(max_len=8192) is Some(chunk) {
    if buffer.length() + chunk.length() > maximum {
      raise @genmit.GenmitError("output exceeds the \{maximum} byte limit")
    }

    buffer.write_bytes(chunk)
  }

  buffer.to_bytes()
}

///|
async fn post_api(request : &@genmit.HttpRequest) -> String {
  let transport = request.transport()

  let headers : @http.Headers = Map([])

  for name, value in transport.headers {
    headers[CaseInsensitiveString(name)] = value
  }

  if transport.auth.env != "" {
    let key = match @env.get_env_var(transport.auth.env) {
      Some(value) if value != "" => value
      _ =>
        raise @genmit.GenmitError(
          "environment variable '\{transport.auth.env}' is required by the selected provider",
        )
    }

    headers[CaseInsensitiveString(transport.auth.header)] = transport.auth.prefix +
      key
  }
  @async.with_timeout(
    180000,
    () => {
      let client = @http.post_stream(transport.endpoint, headers~)

      defer client.close()

      client.write(transport.body.stringify())

      let response = client.end_request()

      let text = read_bounded(client, 4 * 1024 * 1024).text()

      if response.code < 200 || response.code >= 300 {
        let details = @genmit.format_provider_error_details(text)

        raise @genmit.GenmitError(
          if details == "" {
            "provider returned HTTP \{response.code}"
          } else {
            "provider returned HTTP \{response.code}: \{details}"
          },
        )
      }

      request.extract_response(text)
    },
    error=@genmit.GenmitError("provider request timed out after 180000 ms"),
  ) catch {
    error if @async.is_being_cancelled() => raise error
    @genmit.GenmitError(message) => raise @genmit.GenmitError(message)
    error =>
      raise @genmit.GenmitError("provider request failed: \{error.to_string()}")
  }
}

///|
/// Execute a prepared provider using portable HTTP and a host process runner.
async fn call_provider(
  provider : @genmit.SelectedProvider,
  prompt : @genmit.Prompt,
  cwd : String,
  runner : async (ProcessRequest) -> ProcessOutput,
) -> String {
  match provider.prepare_request(prompt) {
    Process(executable~, args~, input~) => {
      let output = execute_process(
        {
          command: executable,
          args,
          cwd,
          input,
          timeout_ms: 180000,
          maximum_output_bytes: 4 * 1024 * 1024,
        },
        runner,
      )

      if output.code != 0 {
        let details = @genmit.format_provider_error_details(output.stderr)

        raise @genmit.GenmitError(
          if details == "" {
            "command '\{executable}' exited with code \{output.code}"
          } else {
            "command '\{executable}' exited with code \{output.code}: \{details}"
          },
        )
      }

      output.stdout
    }
    Http(request) => post_api(request)
  }
}
