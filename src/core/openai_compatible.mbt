///|
priv struct OpenAICompatibleRequest {
  transport : HttpTransport
}

///|
priv struct OpenAICompatibleApi {} derive(Debug)

///|
impl ApiProvider for OpenAICompatibleApi with fn prepare_request(
  _self,
  config,
  prompt,
) {
  let body = {
    "model": Json(config.model),
    "messages": [
      { "role": "system", "content": Json(prompt.instructions) },
      { "role": "user", "content": Json(prompt.data) },
    ],
    "max_tokens": Json(config.max_tokens),
  }

  if config.reasoning_effort != "" {
    body["reasoning_effort"] = Json(config.reasoning_effort)
  }

  OpenAICompatibleRequest::{
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
impl HttpRequest for OpenAICompatibleRequest with fn transport(self) {
  self.transport
}

///|
impl HttpRequest for OpenAICompatibleRequest with fn extract_response(
  _self,
  input,
) {
  let json = parse_http_response(input)

  guard json
    is {
      "choices": Array(
        [
          {
            "finish_reason": String(reason),
            "message": { "content": String(text), .. },
            ..
          },
          ..,
        ]
      ),
      ..
    } else {
    raise GenmitError("provider response did not contain an assistant message")
  }

  if reason != "stop" {
    raise GenmitError("provider did not finish the commit message: \{reason}")
  }

  text
}
