///|
fn provider_list_output(
  config : @core.Config,
  selected_provider : @core.SelectedProvider,
  json : Bool,
) -> String {
  if json {
    let values : Array[Json] = []

    for (name, kind) in config.provider_kinds() {
      values.push(
        Json::object({
          "name": Json::string(name),
          "kind": Json::string(kind),
          "selected": Json::boolean(name == selected_provider.name()),
        }),
      )
    }

    Json::array(values).stringify() + "\n"
  } else {
    let lines : Array[String] = []

    for (name, kind) in config.provider_kinds() {
      let selected = if name == selected_provider.name() { "*" } else { " " }

      lines.push("\{selected} \{name} (\{kind})")
    }

    lines.join("\n") + "\n"
  }
}

///|
async fn print_providers(options : CliOptions) -> Unit {
  let config = @runtime.load_config(options.cwd, options.config_path)

  let selected_provider = config.select_provider(provider?=options.provider)

  @stdio.stdout.write(
    provider_list_output(config, selected_provider, options.json),
  )
}

///|
fn generation_output(result : @core.GenerationResult, json : Bool) -> String {
  if json {
    result.to_json().stringify() + "\n"
  } else {
    result.message + "\n"
  }
}

///|
async fn run_cli() -> Unit {
  let options = parse_cli(@env.args()[1:])

  match options.action {
    Providers => print_providers(options)
    Prompt => {
      let config_path = options.config_path

      let provider = options.provider

      let prompt = @runtime.preview_prompt(options.cwd, config_path?, provider?)

      @stdio.stdout.write(prompt + "\n")
    }
    Generate => {
      let config_path = options.config_path

      let provider = options.provider

      let result = @runtime.generate(options.cwd, config_path?, provider?, on_event=event => {
        if options.verbose {
          eprintln(event.description())
        }
      })

      if options.verbose {
        @stdio.stderr.write(
          if options.json {
            "\n"
          } else {
            "\nCommit message:\n"
          },
        )
      }

      @stdio.stdout.write(generation_output(result, options.json))
    }
  }
}

///|
async fn main {
  run_cli() catch {
    @core.GenmitError(message) => {
      @stdio.stderr.write("genmit: \{message}\n")
      @sys.exit(1)
    }
    error => {
      @stdio.stderr.write("genmit: unexpected error: \{repr(error)}\n")
      @sys.exit(1)
    }
  }
}
