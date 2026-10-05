///|
fn default_harnesses() -> Map[String, HarnessConfig] {
  {
    "codex": {
      executable: "codex",
      args: [
        "exec", "--ephemeral", "--sandbox", "read-only", "--ignore-user-config",
        "--ignore-rules", "--disable", "shell_tool", "--disable", "hooks", "--disable",
        "apps", "--disable", "multi_agent", "--config", "web_search=\"disabled\"",
        "--config", "project_doc_max_bytes=0",
      ],
      parameters: {
        "model": { required: true, args: ["--model", "${value}"], },
        "reasoning_effort": {
          required: false,
          args: ["--config", "model_reasoning_effort=${value}"],
        },
      },
      tail_args: ["-"],
    },
  }
}

///|
fn default_providers() -> Map[String, ProviderConfig] {
  {
    "codex": Harness({
      harness: "codex",
      config: { "model": "gpt-6-luna", "reasoning_effort": "low" },
    }),
    "openai": Api(OpenAIResponses, {
      endpoint: "https://api.openai.com/v1/responses",
      model: "gpt-6-luna",
      reasoning_effort: "low",
      api_key_env: "OPENAI_API_KEY",
      max_tokens: 1024,
    }),
    "anthropic": Api(AnthropicMessages, {
      endpoint: "https://api.anthropic.com/v1/messages",
      model: "claude-sonnet-5",
      reasoning_effort: "low",
      api_key_env: "ANTHROPIC_API_KEY",
      max_tokens: 1024,
    }),
  }
}

///|
/// Defaults are useful without an API key when the user is already signed in
/// to the Codex CLI with a ChatGPT account.
pub fn default_config() -> Config {
  let harnesses = default_harnesses()

  let providers = default_providers()

  try! Config(
    provider="codex",
    language="en",
    style=Conventional,
    include_body=true,
    max_subject_length=72,
    extra_prompt="",
    max_provider_calls=32,
    generation_timeout_ms=600000,
    harnesses~,
    providers~,
  )
}

///|
fn ProviderConfig::kind_name(self : ProviderConfig) -> String {
  match self {
    Harness(config) => config.harness
    Api(kind, _) => kind.name()
  }
}

///|
fn ApiKind::name(self : ApiKind) -> String {
  match self {
    OpenAIResponses => "openai-responses"
    OpenAICompatible => "openai-compatible"
    AnthropicMessages => "anthropic-messages"
  }
}

///|
fn configure_api_provider(
  name : String,
  kind : ApiKind,
  config : ApiConfig,
) -> SelectedProviderData raise GenmitError {
  if config.endpoint.trim() == "" {
    raise GenmitError("providers.\{name}.config.endpoint must not be empty")
  }

  if config.model.trim() == "" {
    raise GenmitError("providers.\{name}.config.model must not be empty")
  }

  if config.max_tokens <= 0 {
    raise GenmitError("providers.\{name}.config.max_tokens must be positive")
  }

  let provider : &ApiProvider = match kind {
    OpenAIResponses => {
      let provider : &ApiProvider = OpenAIResponsesApi::{ }
      provider
    }
    OpenAICompatible => {
      let provider : &ApiProvider = OpenAICompatibleApi::{ }
      provider
    }
    AnthropicMessages => {
      let provider : &ApiProvider = AnthropicMessagesApi::{ }
      provider
    }
  }

  Api(provider, config)
}

///|
/// Create a complete configuration and establish all of its invariants.
fn Config::Config(
  provider~ : String,
  language~ : String,
  style~ : CommitStyle,
  include_body~ : Bool,
  max_subject_length~ : Int,
  extra_prompt~ : String,
  max_provider_calls~ : Int,
  generation_timeout_ms~ : Int,
  harnesses~ : Map[String, HarnessConfig],
  providers~ : Map[String, ProviderConfig],
) -> Config raise GenmitError {
  if max_subject_length < 20 || max_subject_length > 200 {
    raise GenmitError("max_subject_length must be between 20 and 200")
  }

  if language.trim() == "" {
    raise GenmitError("language must not be empty")
  }

  if max_provider_calls <= 0 {
    raise GenmitError("generation.max_provider_calls must be positive")
  }

  if generation_timeout_ms <= 0 {
    raise GenmitError("generation.timeout_ms must be positive")
  }

  if !providers.contains(provider) {
    raise GenmitError(
      "provider '\{provider}' has no matching [providers.\{provider}] table",
    )
  }

  for name, harness in harnesses {
    match name.to_lower() {
      "openai-responses" | "openai-compatible" | "anthropic-messages" =>
        raise GenmitError(
          "harness name '\{name}' conflicts with a built-in API kind",
        )
      _ => ()
    }

    if harness.executable.trim() == "" {
      raise GenmitError("harnesses.\{name}.executable must not be empty")
    }
  }

  let configured_providers = Map([])

  for name, provider_config in providers {
    let data : SelectedProviderData = match provider_config {
      Harness(value) => {
        guard harnesses.get(value.harness) is Some(harness) else {
          raise GenmitError(
            "provider '\{name}' references unknown harness '\{value.harness}'",
          )
        }

        for key, _ in value.config {
          if !harness.parameters.contains(key) {
            raise GenmitError(
              "providers.\{name}.config.\{key} is not a parameter of harness '\{value.harness}'",
            )
          }
        }

        for key, parameter in harness.parameters {
          if parameter.required {
            match value.config.get(key) {
              Some(parameter_value) if parameter_value.trim() != "" => ()
              _ =>
                raise GenmitError(
                  "providers.\{name}.config.\{key} must not be empty",
                )
            }
          }
        }

        Harness(harness, value)
      }
      Api(kind, config) => configure_api_provider(name, kind, config)
    }

    configured_providers[name] = { config: provider_config, data, }
  }

  {
    provider,
    language,
    style,
    include_body,
    max_subject_length,
    extra_prompt,
    max_provider_calls,
    generation_timeout_ms,
    harnesses,
    providers: configured_providers,
  }
}

///|
/// Select an already validated provider from this configuration.
pub fn Config::select_provider(
  self : Config,
  provider? : String,
) -> SelectedProvider raise GenmitError {
  let name = provider.unwrap_or(self.provider)

  guard self.providers.get(name) is Some(provider) else {
    raise GenmitError("provider '\{name}' is not configured")
  }

  { name, data: provider.data, }
}

///|
/// Return configured provider names and their harness or API kinds.
pub fn Config::provider_kinds(self : Config) -> Array[(String, String)] {
  let result = []

  for name, provider in self.providers {
    result.push((name, provider.config.kind_name()))
  }

  result
}
