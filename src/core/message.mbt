///|
/// Normalize common model wrappers while preserving a subject/body message.
pub fn normalize_message(output : String) -> String raise GenmitError {
  let normalized = output.replace_all(old="\r\n", new="\n")

  let lines : Array[StringView] = []

  for line in normalized.split("\n") {
    if !line.trim().has_prefix("```") {
      for char in line {
        if char.is_control() {
          raise GenmitError(
            "the selected provider returned an invalid control character: \{char.escape(quote=false)}",
          )
        }
      }

      lines.push(line)
    }
  }

  let message = lines.join("\n").trim().to_owned()

  if message == "" {
    raise GenmitError("the selected provider returned an empty commit message")
  }

  message
}

///|
fn wrap_body(body : StringView, width : Int32) -> String {
  body
  .split("\n")
  .map(line => {
    if line.char_length() <= width {
      return line.to_owned()
    }
    let wrapped = StringBuilder()
    let mut current_length = 0
    for word in line.split(" ").filter(word => !word.is_empty()) {
      let word_length = word.char_length()
      if current_length > 0 && current_length + 1 + word_length > width {
        wrapped.write_char('\n')
        current_length = 0
      }
      if current_length > 0 {
        wrapped.write_char(' ')
        current_length += 1
      }
      wrapped.write_stringview(word)
      current_length += word_length
    }
    wrapped.to_string()
  })
  .join("\n")
}

///|
/// Normalize and enforce the output constraints of a resolved configuration.
pub fn Config::normalize_message(
  self : Config,
  output : String,
) -> String raise GenmitError {
  let message = normalize_message(output)

  let (subject, body) = message.split_once("\n").unwrap_or((message[:], ""))

  if subject.char_length() > self.max_subject_length {
    raise GenmitError(
      "the generated subject exceeds the \{self.max_subject_length} character limit",
    )
  }

  if !self.include_body {
    return subject.to_owned()
  }

  if self.body_wrap_width == 0 || body.is_empty() {
    return message
  }

  "\{subject}\n\{wrap_body(body, self.body_wrap_width)}"
}
