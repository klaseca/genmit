///|
test "body wrapping preserves paragraphs and the subject" {
  let config = test_config(
    (
      #|body_wrap_width = 24
      #|max_subject_length = 60
    ),
  )

  let message =
    #|feat: wrap generated commit messages
    #|
    #|Wrap long body lines at the configured width without changing the subject.
    #|
    #|Keep this paragraph.
    #|Keep this line break.

  let expected =
    #|feat: wrap generated commit messages
    #|
    #|Wrap long body lines at
    #|the configured width
    #|without changing the
    #|subject.
    #|
    #|Keep this paragraph.
    #|Keep this line break.

  let normalized = config.normalize_message(message)

  assert_eq(normalized, expected)
  assert_eq(config.normalize_message(normalized), normalized)
}

///|
test "body wrapping counts Unicode characters without splitting words" {
  let config = test_config("body_wrap_width = 10")

  let message =
    #|feat: Unicode
    #|
    #|Привет 🌙🌙🌙 мир

  let expected =
    #|feat: Unicode
    #|
    #|Привет 🌙🌙🌙
    #|мир

  assert_eq(config.normalize_message(message), expected)
}

///|
test "body wrapping keeps long tokens intact" {
  let config = test_config("body_wrap_width = 24")

  let message =
    #|feat: link documentation
    #|
    #|See https://example.test/docs/generation/configuration for details.

  let expected =
    #|feat: link documentation
    #|
    #|See
    #|https://example.test/docs/generation/configuration
    #|for details.

  assert_eq(config.normalize_message(message), expected)
}

///|
test "body wrapping can be disabled independently of subject validation" {
  let config = test_config(
    (
      #|body_wrap_width = 0
      #|max_subject_length = 20
    ),
  )

  let message =
    #|feat: message
    #|
    #|Keep this long body line unchanged even when it exceeds the usual wrapping width.
  assert_eq(config.normalize_message(message), message)
}
