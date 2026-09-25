///|
test "user config path prefers GENMIT_HOME and falls back to HOME" {
  let genmit_home : @path.Path = "custom-genmit-home"
  let home : @path.Path = "user-home"
  assert_eq(
    user_config_path(Some(genmit_home.to_string()), Some(home.to_string())),
    Some(genmit_home.join("config.toml").to_string()),
  )
  assert_eq(
    user_config_path(Some(""), Some(home.to_string())),
    Some(home.join(".config").join("genmit").join("config.toml").to_string()),
  )
  assert_eq(user_config_path(None, None), None)
}
