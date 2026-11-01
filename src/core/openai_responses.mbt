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
    "model": Json(config.model),
    "store": Json(false),
    "instructions": Json(prompt.instructions),
    "input": Json(prompt.data),
    "max_output_tokens": Json(config.max_tokens),
  }

  if config.reasoning_effort != "" {
    body["reasoning"] = { "effort": Json(config.reasoning_effort) }
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
