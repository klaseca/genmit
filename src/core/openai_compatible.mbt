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
    "model": config.model.to_json(),
    "messages": [
      { "role": "system", "content": prompt.instructions.to_json() },
      { "role": "user", "content": prompt.data.to_json() },
    ],
    "max_tokens": config.max_tokens.to_json(),
  }

  if config.reasoning_effort != "" {
    body["reasoning_effort"] = config.reasoning_effort.to_json()
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
