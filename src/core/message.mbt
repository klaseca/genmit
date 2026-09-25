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
/// Normalize and enforce the output constraints of a resolved configuration.
pub fn Config::normalize_message(
  self : Config,
  output : String,
) -> String raise GenmitError {
  let message = normalize_message(output)

  let lines = message.split("\n").to_array()

  let subject = lines[0]

  if subject.char_length() > self.max_subject_length {
    raise GenmitError(
      "the generated subject exceeds the \{self.max_subject_length} character limit",
    )
  }

  if !self.include_body && lines.length() > 1 {
    raise GenmitError(
      "the selected provider returned a commit body while include_body is false",
    )
  }

  message
}
