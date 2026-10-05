///|
enum Action {
  Generate
  Prompt
  Providers
} derive(Debug, Eq)

///|
struct CliOptions {
  action : Action
  cwd : String
  config_path : String?
  provider : String?
  json : Bool
  verbose : Bool
} derive(Debug)

///|
fn json_flag() -> @argparse.FlagArg {
  FlagArg("json", about="Print machine-readable JSON")
}

///|
fn cli_command() -> @argparse.Command {
  Command(
    "genmit",
    about="Generate a Git commit message from staged changes",
    version=VERSION,
    flags=[
      FlagArg(
        "verbose",
        short='v',
        about="Log generation stages, outcomes, and timings to stderr",
        global=true,
      ),
    ],
    options=[
      OptionArg(
        "cwd",
        short='C',
        about="Use this directory as the Git repository and config base",
        global=true,
      ),
      OptionArg(
        "config",
        short='c',
        about="Use this TOML file instead of the discovered user config",
        global=true,
      ),
      OptionArg(
        "provider",
        short='p',
        about="Use this named provider instead of the config default",
        global=true,
      ),
    ],
    subcommands=[
      Command("generate", about="Generate a commit message", flags=[json_flag()]),
      Command(
        "prompt",
        about="Print the prompt without contacting the provider",
      ),
      Command(
        "providers",
        about="List providers from the active configuration",
        flags=[json_flag()],
      ),
    ],
    disable_help_subcommand=true,
  )
}

///|
fn parse_cli(args : ArrayView[String]) -> CliOptions raise @core.GenmitError {
  let matches = cli_command().parse(argv=args) catch {
    error => raise GenmitError(error.to_string())
  }

  let (action, command) = match matches.subcommand {
    Some(("generate", command)) => (Generate, command)
    Some(("prompt", command)) => (Prompt, command)
    Some(("providers", command)) => (Providers, command)
    Some(_) => raise GenmitError("unknown command")
    None => (Generate, matches)
  }

  let cwd = match matches.values.get("cwd") {
    Some([value]) => value
    _ => @env.current_dir().unwrap_or(".")
  }

  let config_path = match matches.values.get("config") {
    Some([value]) => Some(value)
    _ => None
  }

  let provider = match matches.values.get("provider") {
    Some([value]) => Some(value)
    _ => None
  }

  {
    action,
    cwd,
    config_path,
    provider,
    json: command.flags.get("json").unwrap_or(false),
    verbose: matches.flags.get("verbose").unwrap_or(false),
  }
}
