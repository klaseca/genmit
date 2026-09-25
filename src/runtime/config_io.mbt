///|
fn resolve_from(base : String, path : String) -> String {
  let path : @path.Path = path

  if path.is_absolute() {
    path.to_string()
  } else {
    let base : @path.Path = base

    base.join(path).to_string()
  }
}

///|
/// Resolve the user-level config without reading process environment.
fn user_config_path(genmit_home : String?, home : String?) -> String? {
  match genmit_home {
    Some(base) if base != "" => {
      let base : @path.Path = base

      Some(base.join("config.toml").to_string())
    }
    _ =>
      match home {
        Some(base) if base != "" => {
          let base : @path.Path = base

          Some(
            base.join(".config").join("genmit").join("config.toml").to_string(),
          )
        }
        _ => None
      }
  }
}

///|
fn home_dir() -> String? {
  if is_windows {
    match @env.get_env_var("USERPROFILE") {
      Some(path) => Some(path)
      None => @env.get_env_var("HOME")
    }
  } else {
    @env.get_env_var("HOME")
  }
}

///|
fn global_config_path() -> String? {
  user_config_path(@env.get_env_var("GENMIT_HOME"), home_dir())
}

///|
async fn load_config_file(path : String) -> @genmit.Config {
  let contents = @fs.read_file(path).text() catch {
    error =>
      raise @genmit.GenmitError(
        "failed to read config '\{path}': \{repr(error)}",
      )
  }

  @genmit.Config::from_toml(contents) catch {
    GenmitError(message) =>
      raise @genmit.GenmitError("failed to load config '\{path}': \{message}")
  }
}

///|
/// Load an explicit TOML file or the user-level config.
/// An explicit file replaces user-config discovery rather than extending it.
/// Relative explicit paths are resolved from `base`.
pub async fn load_config(
  base : String,
  explicit_path : String?,
) -> @genmit.Config {
  match explicit_path {
    Some(path) => {
      let resolved = resolve_from(base, path)

      if !@fs.exists(resolved) {
        raise @genmit.GenmitError("config file '\{resolved}' does not exist")
      }

      load_config_file(resolved)
    }
    None =>
      match global_config_path() {
        Some(path) if @fs.exists(path) => load_config_file(path)
        _ => @genmit.default_config()
      }
  }
}
