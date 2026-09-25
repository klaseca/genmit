///|
priv struct AnthropicMessagesRequest {
  transport : HttpTransport
}

///|
priv struct AnthropicMessagesApi {} derive(Debug)

///|
impl ApiProvider for AnthropicMessagesApi with fn prepare_request(
  _self,
  config,
  prompt,
) {
  let body = {
    "model": config.model.to_json(),
    "system": prompt.instructions.to_json(),
    "messages": [{ "role": "user", "content": prompt.data.to_json() }],
    "max_tokens": config.max_tokens.to_json(),
  }

  if config.reasoning_effort != "" {
    body["output_config"] = { "effort": config.reasoning_effort.to_json() }
  }

  AnthropicMessagesRequest::{
    transport: {
      endpoint: config.endpoint,
      headers: {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
      },
      auth: { env: config.api_key_env, header: "x-api-key", prefix: "", },
      body: Json::object(body),
    },
  }
}

///|
impl HttpRequest for AnthropicMessagesRequest with fn transport(self) {
  self.transport
}

///|
impl HttpRequest for AnthropicMessagesRequest with fn extract_response(
  _self,
  input,
) {
  let json = parse_http_response(input)

  guard json is { "stop_reason": String(reason), .. } else {
    raise GenmitError("provider response did not contain a completion status")
  }

  if reason != "end_turn" {
    raise GenmitError("provider did not finish the commit message: \{reason}")
  }

  guard json is { "content": Array(contents), .. } &&
    text_blocks(contents, "text") is Some(text) else {
    raise GenmitError("provider response did not contain an assistant message")
  }

  text
}
