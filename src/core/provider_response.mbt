///|
const PROVIDER_ERROR_DETAILS_LIMIT = 1000

///|
pub fn format_provider_error_details(input : String) -> String {
  let escaped = StringBuilder()

  for char in input {
    if char != '\n' && char.is_control() {
      escaped.write_string(char.escape(quote=false))
    } else {
      escaped.write_char(char)
    }
  }

  let details = escaped.to_string().trim().to_owned()

  if details.char_length() > PROVIDER_ERROR_DETAILS_LIMIT {
    let end = details.offset_of_nth_char(PROVIDER_ERROR_DETAILS_LIMIT).unwrap()

    details.view(end_offset=end).to_owned() + "..."
  } else {
    details
  }
}

///|
fn provider_error_message(error : Json) -> String {
  format_provider_error_details(
    match error {
      { "message": String(message), .. } if message.trim() != "" => message
      String(message) if message.trim() != "" => message
      _ => error.stringify()
    },
  )
}

///|
fn parse_http_response(input : String) -> Json raise GenmitError {
  let json = @json.parse(input) catch {
    error => raise GenmitError("provider returned invalid JSON: \{repr(error)}")
  }

  match json {
    { "error": Object(error), .. } =>
      raise GenmitError(
        "provider returned an error: \{provider_error_message(Json::object(error))}",
      )
    { "error": String(message), .. } if message.trim() != "" =>
      raise GenmitError(
        "provider returned an error: \{provider_error_message(message.to_json())}",
      )
    _ => json
  }
}

///|
fn text_blocks(contents : Array[Json], kind : String) -> String? {
  let parts = []

  for content in contents {
    match content {
      { "type": String(block_kind), "text": String(text), .. } if block_kind ==
        kind => parts.push(text)
      _ => ()
    }
  }

  let text = parts.join("")

  if text.trim() == "" {
    None
  } else {
    Some(text)
  }
}
