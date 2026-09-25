///|
async test "explicit config supports relative and absolute paths" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="genmit-config-test")
    let root_path : @path.Path = root
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root, recursive=true))
    }
    let explicit_config =
      #|language = "from-explicit"
      #|
      #|[providers.codex.config]
      #|model = "test-model"
      #|
    let explicit_path = root_path.join("explicit.toml").to_string()
    @fs.write_file(explicit_path, explicit_config)
    let config = @runtime.load_config(root, Some("explicit.toml"))
    assert_eq(config.language, "from-explicit")
    let absolute_config = @runtime.load_config(
      root_path.join("unused").to_string(),
      Some(explicit_path),
    )
    assert_eq(absolute_config.language, "from-explicit")
  }
}
