///|
fn test_command(script : String) -> (String, Array[String]) {
  if is_windows {
    ("powershell.exe", ["-NoProfile", "-Command", script])
  } else {
    ("/bin/sh", ["-c", script])
  }
}

///|
async test "process captures stdin, stdout, stderr, and Unicode" {
  let script = if is_windows {
    "$text = [Console]::In.ReadToEnd(); [Console]::Out.Write($text); [Console]::Error.Write('diagnostic')"
  } else {
    "cat; printf 'diagnostic' >&2"
  }
  let (command, args) = test_command(script)
  let (code, stdout, stderr) = collect_process(
    command,
    args,
    ".",
    "Hello 🌙",
    timeout_ms=5000,
    maximum=1024,
  )
  assert_eq(code, 0)
  assert_eq(stdout, "Hello 🌙")
  assert_eq(stderr, "diagnostic")
}

///|
async test "process exit diagnostics take precedence over a closed stdin" {
  let script = if is_windows {
    "[Console]::OpenStandardInput().Close(); Start-Sleep -Milliseconds 200; [Console]::Error.Write('expected failure'); exit 23"
  } else {
    "exec 0<&-; sleep 0.2; printf 'expected failure' >&2; exit 23"
  }
  let (command, args) = test_command(script)
  let (code, _, stderr) = collect_process(
    command,
    args,
    ".",
    "x".repeat(1024 * 1024),
    timeout_ms=5000,
    maximum=1024,
  )
  assert_eq(code, 23)
  assert_eq(stderr, "expected failure")
}

///|
async test "process output is bounded" {
  let script = if is_windows {
    "[Console]::Out.Write('x' * 10000)"
  } else {
    "printf '%10000s' x"
  }
  let (command, args) = test_command(script)
  try
    collect_process(command, args, ".", "", timeout_ms=5000, maximum=100)
  catch {
    @genmit.GenmitError(message) => assert_true(message.contains("byte limit"))
    error => raise error
  } noraise {
    _ => fail("expected output limit")
  }
}
