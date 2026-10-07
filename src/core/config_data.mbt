///|
priv struct PromptData {
  extra : String?
} derive(FromJson)

///|
priv struct GenerationData {
  max_provider_calls : Int?
  timeout_ms : Int?
} derive(FromJson)

///|
priv struct HarnessParameterData {
  required : Bool?
  args : Array[String]?
} derive(FromJson)

///|
priv struct HarnessDefinitionData {
  executable : String?
  args : Array[String]?
  parameters : Map[String, HarnessParameterData]?
  tail_args : Array[String]?
} derive(FromJson)

///|
priv struct ProviderData {
  kind : String?
  max_input_chars : Int?
  config : Json?
} derive(FromJson)

///|
priv struct ApiConfigData {
  endpoint : String?
  model : String?
  reasoning_effort : String?
  api_key_env : String?
  max_tokens : Int?
} derive(FromJson)

///|
priv struct ConfigData {
  provider : String?
  language : String?
  style : String?
  include_body : Bool?
  max_subject_length : Int?
  prompt : PromptData?
  generation : GenerationData?
  harnesses : Map[String, HarnessDefinitionData]?
  providers : Map[String, ProviderData]?
} derive(FromJson)

///|
fn toml_to_json(value : @toml.TomlValue) -> Json raise GenmitError {
  match value {
    TomlString(value) => Json::string(value)
    TomlInteger(value) =>
      Json::number(value.to_double(), repr=value.to_string())
    TomlFloat(value) => Json::object({ "$toml_float": Json::number(value) })
    TomlBoolean(value) => Json::boolean(value)
    TomlArray(values) => {
      let result = []
      for value in values {
        result.push(toml_to_json(value))
      }
      Json::array(result)
    }
    TomlTable(values) => {
      let result = Map([])
      for key, value in values {
        result[key] = toml_to_json(value)
      }
      Json::object(result)
    }
    TomlDateTime(value) =>
      Json::object({ "$toml_datetime": Json::string(value.to_string()) })
  }
}

///|
fn[T : @json.FromJson] decode_json(
  value : Json,
  path : String,
) -> T raise GenmitError {
  @json.from_json(value) catch {
    error => {
      let message = error
        .to_string()
        .replace_all(old="overflow", new="integer is out of range")

      raise GenmitError("invalid config at '\{path}': \{message}")
    }
  }
}

///|
fn merge_harness(
  data : HarnessDefinitionData,
  default : HarnessDefinition?,
) -> HarnessDefinition {
  let fallback = default.unwrap_or({
    executable: "",
    args: [],
    parameters: Map([]),
    tail_args: [],
  })

  let parameters = fallback.parameters.copy()

  for parameter_name, parameter in data.parameters.unwrap_or(Map([])) {
    let parameter_default = parameters
      .get(parameter_name)
      .unwrap_or({ required: false, args: [], })

    parameters[parameter_name] = {
      required: parameter.required.unwrap_or(parameter_default.required),
      args: parameter.args.unwrap_or(parameter_default.args),
    }
  }

  {
    executable: data.executable.unwrap_or(fallback.executable),
    args: data.args.unwrap_or(fallback.args),
    parameters,
    tail_args: data.tail_args.unwrap_or(fallback.tail_args),
  }
}

///|
fn build_api_config(data : ApiConfigData, defaults : ApiConfig?) -> ApiConfig {
  let defaults = defaults.unwrap_or({
    endpoint: "",
    model: "",
    reasoning_effort: "",
    api_key_env: "",
    max_tokens: 1024,
  })

  {
    endpoint: data.endpoint.unwrap_or(defaults.endpoint),
    model: data.model.unwrap_or(defaults.model),
    reasoning_effort: data.reasoning_effort.unwrap_or(defaults.reasoning_effort),
    api_key_env: data.api_key_env.unwrap_or(defaults.api_key_env),
    max_tokens: data.max_tokens.unwrap_or(defaults.max_tokens),
  }
}

///|
fn build_provider(
  data : ProviderData,
  name : String,
  default : ProviderConfig?,
  harnesses : Map[String, HarnessDefinition],
) -> ProviderConfig raise GenmitError {
  let kind = match data.kind {
    Some(value) => value
    None =>
      match default {
        Some(value) => value.kind_name()
        None =>
          raise GenmitError(
            "provider '\{name}' must define 'providers.\{name}.kind'",
          )
      }
  }

  let path = "providers.\{name}"

  let settings : ProviderSettings = {
    max_input_chars: data.max_input_chars.unwrap_or(
      default
      .map(value => value.settings.max_input_chars)
      .unwrap_or(default_max_input_chars),
    ),
  }
  let raw_config = data.config.unwrap_or(Json::object(Map([])))
  let defaults = default.map(value => value.backend)

  let backend : ProviderBackendConfig = if harnesses.contains(kind) {
    let parameters = match defaults {
      Some(Harness(value)) if value.harness == kind => value.parameters.copy()
      _ => Map([])
    }
    let configured_parameters : Map[String, String] = decode_json(
      raw_config,
      "\{path}.config",
    )
    for key, value in configured_parameters {
      parameters[key] = value
    }
    Harness({ harness: kind, parameters, })
  } else {
    let api_kind = parse_api_kind(kind)

    let data : ApiConfigData = decode_json(raw_config, "\{path}.config")

    let defaults = match defaults {
      Some(Api(default_kind, config)) if default_kind == api_kind =>
        Some(config)
      _ => None
    }

    Api(api_kind, build_api_config(data, defaults))
  }
  { settings, backend, }
}

///|
fn parse_api_kind(kind : String) -> ApiKind raise GenmitError {
  match kind.to_lower() {
    "openai-responses" => OpenAIResponses
    "openai-compatible" => OpenAICompatible
    "anthropic-messages" => AnthropicMessages
    _ => raise GenmitError("unknown provider kind '\{kind}'")
  }
}

///|
fn ConfigData::to_config(self : ConfigData) -> Config raise GenmitError {
  let defaults = default_config()

  let provider = self.provider.unwrap_or(defaults.provider)

  let language = self.language.unwrap_or(defaults.language)

  let style = match self.style {
    Some(value) => parse_commit_style(value)
    None => defaults.style
  }

  let include_body = self.include_body.unwrap_or(defaults.include_body)

  let max_subject_length = self.max_subject_length.unwrap_or(
    defaults.max_subject_length,
  )

  let extra_prompt = match self.prompt {
    Some(prompt) => prompt.extra.unwrap_or(defaults.extra_prompt)
    None => defaults.extra_prompt
  }

  let (max_provider_calls, generation_timeout_ms) = match self.generation {
    Some(generation) =>
      (
        generation.max_provider_calls.unwrap_or(defaults.max_provider_calls),
        generation.timeout_ms.unwrap_or(defaults.generation_timeout_ms),
      )
    None => (defaults.max_provider_calls, defaults.generation_timeout_ms)
  }

  let harnesses = defaults.harnesses.copy()

  for name, data in self.harnesses.unwrap_or(Map([])) {
    harnesses[name] = merge_harness(data, harnesses.get(name))
  }

  let providers = Map([])

  for name, provider in defaults.providers {
    providers[name] = provider.config
  }

  for name, data in self.providers.unwrap_or(Map([])) {
    providers[name] = build_provider(data, name, providers.get(name), harnesses)
  }

  Config(
    provider~,
    language~,
    style~,
    include_body~,
    max_subject_length~,
    extra_prompt~,
    max_provider_calls~,
    generation_timeout_ms~,
    harnesses~,
    providers~,
  )
}

///|
/// Create a configuration by applying TOML values to genmit's defaults.
pub fn Config::from_toml(data : String) -> Config raise GenmitError {
  let parsed = @toml.parse(data) catch {
    error => raise GenmitError("invalid TOML: \{repr(error)}")
  }

  guard parsed is TomlTable(_) else {
    raise GenmitError("the TOML document root must be a table")
  }

  let value = toml_to_json(parsed)

  let config_data : ConfigData = decode_json(value, "root")

  config_data.to_config()
}
