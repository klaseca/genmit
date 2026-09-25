///|
priv struct OpenAIResponsesRequest {
  transport : HttpTransport
}

///|
priv struct OpenAIResponsesApi {} derive(Debug)

///|
impl ApiProvider for OpenAIResponsesApi with fn prepare_request(
  _self,
  config,
  prompt,
) {
  let body = {
    "model": config.model.to_json(),
    "store": false.to_json(),
    "instructions": prompt.instructions.to_json(),
    "input": prompt.data.to_json(),
    "max_output_tokens": config.max_tokens.to_json(),
  }

  if config.reasoning_effort != "" {
    body["reasoning"] = { "effort": config.reasoning_effort.to_json() }
  }

  OpenAIResponsesRequest::{
    transport: {
      endpoint: config.endpoint,
      headers: { "content-type": "application/json" },
      auth: {
        env: config.api_key_env,
        header: "authorization",
        prefix: "Bearer ",
      },
      body: Json::object(body),
    },
  }
}

///|
impl HttpRequest for OpenAIResponsesRequest with fn transport(self) {
  self.transport
}

///|
impl HttpRequest for OpenAIResponsesRequest with fn extract_response(
  _self,
  input,
) {
  let json = parse_http_response(input)

  guard json is { "status": String(status), .. } else {
    raise GenmitError("provider response did not contain a completion status")
  }

  if status != "completed" {
    raise GenmitError("provider response is not complete: \{status}")
  }

  guard json is { "output": Array(items), .. } else {
    raise GenmitError("provider response did not contain an assistant message")
  }

  for item in items {
    if item is { "type": "message", "content": Array(contents), .. } &&
      text_blocks(contents, "output_text") is Some(text) {
      return text
    }
  }

  raise GenmitError("provider response did not contain an assistant message")
}
