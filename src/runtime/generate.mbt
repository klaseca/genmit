///|
/// Generate a message within the configured whole-generation budget.
pub async fn generate(
  cwd : String,
  config_path? : String,
  provider? : String,
  on_event? : (@host.GenerationEvent) -> Unit = _ => (),
) -> @genmit.GenerationResult {
  let config = load_config(cwd, config_path)

  let selected_provider = config.select_provider(provider?)

  @host.generate(config, selected_provider, cwd, run_host_process, on_event~)
}

///|
/// Build the direct single-request prompt without contacting an AI provider.
pub async fn preview_prompt(
  cwd : String,
  config_path? : String,
  provider? : String,
) -> String {
  let config = load_config(cwd, config_path)

  config.select_provider(provider?) |> ignore

  @host.prepare_prompt(config, cwd, run_host_process)
}
