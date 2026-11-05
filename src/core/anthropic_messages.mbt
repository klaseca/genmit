///|
priv struct AnthropicMessagesRequest {
  transport : HttpTransport
}

///|
#derive(Debug)
priv struct AnthropicMessagesApi {}

///|
impl ApiProvider for AnthropicMessagesApi with fn prepare_request(
  _self,
  config,
  prompt,
) {
  let body = {
    "model": Json(config.model),
    "system": Json(prompt.instructions),
    "messages": [{ "role": "user", "content": Json(prompt.data) }],
    "max_tokens": Json(config.max_tokens),
  }

  if config.reasoning_effort != "" {
    body["output_config"] = { "effort": Json(config.reasoning_effort) }
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
