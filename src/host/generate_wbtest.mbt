///|
test "diff chunks use the configured request budget" {
  let diff = "diff --git a/large b/large\n--- a/large\n+++ b/large\n@@ -1 +1 @@\n" +
    "+let value = 12345\n".repeat(7000)
  for name in ["codex", "openai", "anthropic"] {
    for maximum in [16000, 32000, 64000] {
      let config = @genmit.Config::from_toml(
        "[providers.\{name}]\nmax_input_chars = \{maximum}",
      )
      let provider = config.select_provider(provider=name)
      let chunks = diff_chunks_for_provider(provider, diff, config)
      assert_eq(chunks.map(chunk => chunk.content).join(""), diff)
      for index, chunk in chunks {
        let size = provider_request_chars(
          provider,
          @genmit.build_diff_summary_prompt(chunk, index + 1, chunks.length()),
        )
        assert_true(size <= maximum)
        if index + 1 < chunks.length() {
          assert_true(size >= maximum * 9 / 10)
        }
      }
    }
  }
}

///|
test "escaped long lines do not shrink unrelated diff chunks" {
  let ordinary = "diff --git a/ordinary b/ordinary\n@@ -1 +1 @@\n" +
    "+value\n".repeat(15000)
  let escaped = "diff --git a/escaped b/escaped\n--- a/escaped\n+++ b/escaped\n@@ -1 +1 @@\n+" +
    "\"\\🌙".repeat(4000) +
    "\n"
  let diff = ordinary + escaped
  let config = @genmit.Config::from_toml(
    "[providers.openai]\nmax_input_chars = 32000",
  )
  let provider = config.select_provider(provider="openai")
  let chunks = diff_chunks_for_provider(provider, diff, config)
  assert_eq(chunks.map(chunk => chunk.content).join(""), diff)
  for index, chunk in chunks {
    let size = provider_request_chars(
      provider,
      @genmit.build_diff_summary_prompt(chunk, index + 1, chunks.length()),
    )
    assert_true(size <= provider.max_input_chars())
    if index < 3 {
      assert_true(size >= provider.max_input_chars() * 9 / 10)
    }
  }
}
