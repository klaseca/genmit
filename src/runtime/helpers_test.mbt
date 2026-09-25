///|
let is_windows : Bool = @path.sep == '\\'

///|
async fn run_test_process(
  command : String,
  args : Array[String],
  cwd : String,
) -> Int {
  let (code, _, _) = @process.collect_output(
    command,
    args,
    cwd~,
    no_console_window=true,
  )

  code
}

///|
async fn remove_test_repository(root : String) -> Unit {
  let path : @path.Path = root

  guard path.is_absolute() && path.basename().has_prefix("genmit-test.") else {
    fail("unexpected test repository path")
  }

  if is_windows {
    assert_eq(run_test_process("attrib", ["-R", "*", "/S", "/D"], root), 0)
  }

  @fs.rmdir(root, recursive=true)
}
