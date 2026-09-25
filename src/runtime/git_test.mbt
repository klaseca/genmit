///|
async test "runtime uses the requested cwd for Git and relative config" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="genmit-test.git")
    let path : @path.Path = root
    group.add_defer(() => {
      @async.protect_from_cancel(() => remove_test_repository(root))
    })
    assert_eq(
      run_test_process(
        "git",
        ["init", "--quiet", "--initial-branch=main"],
        root,
      ),
      0,
    )
    try @runtime.preview_prompt(root) catch {
      @genmit.GenmitError(message) =>
        assert_true(message.contains("no staged changes"))
      error => raise error
    } noraise {
      _ => fail("expected empty index error")
    }
    let name = "space 🌙.txt"
    @fs.write_file(path.join(name).to_string(), "staged-content\n")
    assert_eq(run_test_process("git", ["add", "--", name], root), 0)
    @fs.write_file(path.join(name).to_string(), "unstaged-content\n")
    @fs.write_file(
      path.join("untracked.txt").to_string(),
      "untracked-content\n",
    )
    let prompt = @runtime.preview_prompt(root)
    assert_true(prompt.contains(name))
    assert_true(prompt.contains("staged-content"))
    assert_true(!prompt.contains("unstaged-content"))
    assert_true(!prompt.contains("untracked-content"))
    assert_true(prompt.contains("main"))
    assert_true(prompt.contains("No previous commits"))
    let nested = path.join("nested").to_string()
    @fs.mkdir(nested)
    @fs.write_file(
      path.join("nested").join("config.toml").to_string(),
      "language = \"nested-language\"\n",
    )
    let nested_prompt = @runtime.preview_prompt(
      nested,
      config_path="config.toml",
    )
    assert_true(nested_prompt.contains("Language: nested-language."))
  }
}
