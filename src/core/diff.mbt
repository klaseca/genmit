///|
fn split_by_characters(text : String, maximum : Int) -> Array[String] {
  let chunks = []
  let mut remaining = text.view()
  let mut remaining_length = text.char_length()

  while remaining_length > maximum {
    let offset = remaining.offset_of_nth_char(maximum).unwrap()
    chunks.push(remaining.view(end_offset=offset).to_owned())
    remaining = remaining.view(start_offset=offset)
    remaining_length -= maximum
  }

  if remaining_length > 0 {
    chunks.push(remaining.to_owned())
  }

  chunks
}

///|
fn split_at_lines(text : String, maximum : Int) -> Array[String] {
  let chunks = []
  let current = StringBuilder()
  let mut current_length = 0
  let lines = text.split("\n").to_array()

  for index in 0..<lines.length() {
    let suffix = if index + 1 < lines.length() { "\n" } else { "" }
    let line = lines[index].to_owned() + suffix
    let line_length = line.char_length()

    if line_length > maximum {
      if !current.is_empty() {
        chunks.push(current.to_string())
        current.reset()
        current_length = 0
      }
      chunks.append(split_by_characters(line, maximum))
    } else {
      if current_length + line_length > maximum {
        chunks.push(current.to_string())
        current.reset()
        current_length = 0
      }
      current.write_string(line)
      current_length += line_length
    }
  }

  if !current.is_empty() {
    chunks.push(current.to_string())
  }

  chunks
}

///|
fn diff_file_blocks(diff : String) -> Array[String] {
  let blocks = []
  let current = StringBuilder()
  let lines = diff.split("\n").to_array()

  for index in 0..<lines.length() {
    let line = lines[index].to_owned()

    if line.has_prefix("diff --git ") && !current.is_empty() {
      blocks.push(current.to_string())
      current.reset()
    }

    current.write_string(line)
    if index + 1 < lines.length() {
      current.write_string("\n")
    }
  }

  if !current.is_empty() {
    blocks.push(current.to_string())
  }

  blocks
}

///|
fn file_context(block : String) -> String {
  let context = StringBuilder()
  let lines = block.split("\n").to_array()

  for index in 0..<lines.length() {
    let line = lines[index]

    if line.has_prefix("@@") ||
      (line.has_prefix("+") && !line.has_prefix("+++ ")) ||
      (line.has_prefix("-") && !line.has_prefix("--- ")) {
      break
    }

    context.write_stringview(line)

    if index + 1 < lines.length() {
      context.write_string("\n")
    }
  }

  context.to_string()
}

///|
fn contextualize_file_chunks(
  block : String,
  contents : Array[String],
) -> Array[DiffChunk] {
  let chunks = []
  let file_context = file_context(block)
  let mut hunk_context : String? = None

  for content in contents {
    chunks.push({
      content,
      context: Some({ file: file_context, hunk: hunk_context, }),
    })

    for line in content.split("\n") {
      if line.has_prefix("@@") {
        hunk_context = Some(line.to_owned())
      }
    }
  }

  chunks
}

///|
fn complete_chunk(content : String) -> DiffChunk {
  { content, context: None, }
}

///|
/// Split a complete Git diff without dropping or reordering any text. Complete
/// file sections are kept together when they fit; oversized sections are split
/// on line boundaries, and only an individual oversized line is split by
/// Unicode characters.
pub fn split_diff(
  diff : String,
  maximum : Int,
) -> Array[DiffChunk] raise GenmitError {
  if maximum <= 0 {
    raise GenmitError("diff chunk size must be positive")
  }

  let chunks = []
  let current = StringBuilder()
  let mut current_length = 0

  for block in diff_file_blocks(diff) {
    let block_length = block.char_length()

    if block_length > maximum {
      if !current.is_empty() {
        chunks.push(complete_chunk(current.to_string()))
        current.reset()
        current_length = 0
      }

      chunks.append(
        contextualize_file_chunks(block, split_at_lines(block, maximum)),
      )
    } else {
      if current_length + block_length > maximum {
        chunks.push(complete_chunk(current.to_string()))
        current.reset()
        current_length = 0
      }

      current.write_string(block)
      current_length += block_length
    }
  }

  if !current.is_empty() {
    chunks.push(complete_chunk(current.to_string()))
  }

  chunks
}
