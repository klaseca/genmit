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
fn last_hunk(content : String, previous : String?) -> String? {
  let mut hunk = previous
  for line in content.split("\n") {
    if line.has_prefix("@@") {
      hunk = Some(line.to_owned())
    }
  }
  hunk
}

///|
fn split_file(
  block : String,
  maximum : Int,
  fits : (DiffChunk) -> Bool,
) -> Array[DiffChunk] raise GenmitError {
  let chunks = []
  let file = file_context(block)
  let mut remaining = block.view()
  let mut remaining_length = block.char_length()
  let mut hunk_context : String? = None

  while remaining_length > 0 {
    let context = Some({ file, hunk: hunk_context, })
    let mut low = 0
    let mut high = remaining_length.min(maximum)

    // Request size grows with the prefix. Find its largest fitting length,
    // then prefer a line boundary unless the following line itself is too big.
    while low < high {
      let middle = low + (high - low + 1) / 2
      let offset = remaining
        .offset_of_nth_char(middle)
        .unwrap_or(remaining.length())
      let content = remaining.view(end_offset=offset).to_owned()
      if fits({ content, context, }) {
        low = middle
      } else {
        high = middle - 1
      }
    }

    if low == 0 {
      raise GenmitError(
        "max_input_chars is too small for diff context and request instructions",
      )
    }

    let mut end_offset = remaining
      .offset_of_nth_char(low)
      .unwrap_or(remaining.length())
    let mut content = remaining.view(end_offset~).to_owned()

    if low < remaining_length {
      let mut boundary = 0
      let lines = content.split("\n").to_array()
      for index in 0..<(lines.length() - 1) {
        boundary += lines[index].length() + 1
      }

      if boundary > 0 && boundary < end_offset {
        let prefix = remaining.view(end_offset=boundary).to_owned()
        let tail = remaining.view(start_offset=boundary)
        let suffix = if tail.contains("\n") { "\n" } else { "" }
        let next_line = tail.split("\n").head().unwrap().to_owned() + suffix
        let next_context = Some({ file, hunk: last_hunk(prefix, hunk_context), })
        if next_line.char_length() <= maximum &&
          fits({ content: next_line, context: next_context, }) {
          end_offset = boundary
          content = prefix
        }
      }
    }

    chunks.push({ content, context, })
    hunk_context = last_hunk(content, hunk_context)
    remaining = remaining.view(start_offset=end_offset)
    remaining_length -= content.char_length()
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
/// Unicode characters. The optional monotonic predicate also limits each
/// chunk's prepared request, including its continuation context.
pub fn split_diff(
  diff : String,
  maximum : Int,
  fits? : (DiffChunk) -> Bool = _ => true,
) -> Array[DiffChunk] raise GenmitError {
  if maximum <= 0 {
    raise GenmitError("diff chunk size must be positive")
  }

  let chunks = []
  let blocks = diff_file_blocks(diff)
  let lengths = [0]
  for block in blocks {
    lengths.push(lengths.last().unwrap() + block.char_length())
  }

  let mut start = 0
  while start < blocks.length() {
    let block = blocks[start]
    if lengths[start + 1] - lengths[start] > maximum ||
      !fits(complete_chunk(block)) {
      chunks.append(split_file(block, maximum, fits))
      start += 1
      continue
    }

    // Bound the file range by raw character counts before preparing requests.
    let mut low = start + 1
    let mut high = blocks.length()
    while low < high {
      let middle = low + (high - low + 1) / 2
      if lengths[middle] - lengths[start] <= maximum {
        low = middle
      } else {
        high = middle - 1
      }
    }

    let candidate = complete_chunk(blocks[start:low].join(""))
    if low == start + 1 || fits(candidate) {
      chunks.push(candidate)
      start = low
      continue
    }

    // Search whole-file ranges instead of serializing after every added file.
    high = low - 1
    low = start + 1
    while low < high {
      let middle = low + (high - low + 1) / 2
      if fits(complete_chunk(blocks[start:middle].join(""))) {
        low = middle
      } else {
        high = middle - 1
      }
    }
    chunks.push(complete_chunk(blocks[start:low].join("")))
    start = low
  }

  chunks
}
