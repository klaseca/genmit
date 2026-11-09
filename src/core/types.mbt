///|
/// Errors produced by genmit's configuration and pure generation pipeline.
#derive(Debug)
pub(all) suberror GenmitError {
  GenmitError(String)
}

///|
pub extend GenmitError with Debug::{to_repr}

///|
/// Supported commit-message styles.
#derive(Debug, Eq)
pub(all) enum CommitStyle {
  Conventional
  Plain
  Gitmoji
}

///|
pub extend CommitStyle with Debug::{to_repr}

///|
pub extend CommitStyle with Eq::{not_equal, equal}

///|
/// Parse a style used by TOML and CLI frontends.
fn parse_commit_style(value : String) -> CommitStyle raise GenmitError {
  match value.to_lower() {
    "conventional" => Conventional
    "plain" => Plain
    "gitmoji" => Gitmoji
    other =>
      raise GenmitError(
        "unknown commit style '\{other}'; expected conventional, plain, or gitmoji",
      )
  }
}

///|
/// One parameter accepted by a reusable command-line harness.
#derive(Debug, Eq)
priv struct HarnessParameter {
  required : Bool
  args : Array[String]
}

///|
/// Definition of a command-line integration and its accepted parameters.
#derive(Debug, Eq)
priv struct HarnessDefinition {
  executable : String
  args : Array[String]
  parameters : Map[String, HarnessParameter]
  tail_args : Array[String]
}

///|
/// Genmit settings shared by command-line and HTTP providers.
#derive(Debug, Eq)
priv struct ProviderSettings {
  max_input_chars : Int32
}

///|
/// Concrete values supplied to a harness by a provider.
#derive(Debug, Eq)
priv struct HarnessProviderConfig {
  harness : String
  parameters : Map[String, String]
}

///|
/// Configuration shared by the built-in HTTP APIs.
#derive(Debug, Eq)
priv struct ApiConfig {
  endpoint : String
  model : String
  reasoning_effort : String
  api_key_env : String
  max_tokens : Int32
}

///|
/// Wire protocol used by a built-in HTTP API provider.
#derive(Debug, Eq)
priv enum ApiKind {
  OpenAIResponses
  OpenAICompatible
  AnthropicMessages
}

///|
/// A configured provider resolves either to a user-defined harness or to one
/// of the HTTP APIs implemented by genmit.
#derive(Debug, Eq)
priv enum ProviderBackendConfig {
  Harness(HarnessProviderConfig)
  Api(ApiKind, ApiConfig)
}

///|
/// Provider settings and the configuration of its transport.
#derive(Debug, Eq)
priv struct ProviderConfig {
  settings : ProviderSettings
  backend : ProviderBackendConfig
}

///|
/// Behavior shared by the built-in HTTP API providers.
priv trait ApiProvider: Debug {
  fn prepare_request(Self, ApiConfig, Prompt) -> &HttpRequest
}

///|
/// Complete validated application configuration built from defaults and one
/// optional TOML source.
#derive(Debug, Eq)
pub struct Config {
  provider : String
  language : String
  style : CommitStyle
  include_body : Bool
  max_subject_length : Int32
  body_wrap_width : Int32
  extra_prompt : String
  max_provider_calls : Int32
  generation_timeout_ms : Int32
  priv harnesses : Map[String, HarnessDefinition]
  priv providers : Map[String, ConfiguredProvider]
}

///|
pub extend Config with Debug::{to_repr}

///|
pub extend Config with Eq::{not_equal, equal}

///|
#derive(Debug)
priv enum SelectedProviderData {
  Harness(executable~ : String, args~ : Array[String], model~ : String?)
  Api(&ApiProvider, ApiConfig)
}

///|
/// A provider configuration resolved into data that can prepare requests.
#derive(Debug)
priv struct ConfiguredProvider {
  config : ProviderConfig
  data : SelectedProviderData
}

///|
impl Eq for ConfiguredProvider with fn equal(self, other) {
  self.config == other.config
}

///|
/// A selected and validated provider.
#derive(Debug)
pub struct SelectedProvider {
  priv name : String
  priv settings : ProviderSettings
  priv data : SelectedProviderData
}

///|
pub extend SelectedProvider with Debug::{to_repr}

///|
/// Git information passed to a provider. It deliberately contains only staged
/// changes; unstaged files never become an implicit fallback.
#derive(Debug, Eq)
pub(all) struct GitContext {
  root : String
  branch : String
  staged_files : Array[String]
  diff : String
  recent_commits : String
}

///|
pub extend GitContext with Debug::{to_repr}

///|
pub extend GitContext with Eq::{not_equal, equal}

///|
/// File and optional hunk context needed to understand a diff continuation.
#derive(Debug, Eq)
pub(all) struct DiffContext {
  file : String
  hunk : String?
}

///|
pub extend DiffContext with Debug::{to_repr}

///|
pub extend DiffContext with Eq::{not_equal, equal}

///|
/// A lossless part of a Git diff. Context is present only when a file section
/// had to be split into multiple chunks.
#derive(Debug, Eq)
pub(all) struct DiffChunk {
  content : String
  context : DiffContext?
}

///|
pub extend DiffChunk with Debug::{to_repr}

///|
pub extend DiffChunk with Eq::{not_equal, equal}

///|
/// Provider instructions and untrusted Git data kept separate for transports
/// that support privileged system or developer messages.
#derive(Debug, Eq)
pub(all) struct Prompt {
  instructions : String
  data : String
}

///|
pub extend Prompt with Debug::{to_repr}

///|
pub extend Prompt with Eq::{not_equal, equal}

///|
/// Machine-readable result shared by CLI, VS Code, and future frontends.
#derive(Debug, ToJson)
pub(all) struct GenerationResult {
  protocol_version : Int32
  message : String
  provider : String
  files : Array[String]
}

///|
pub extend GenerationResult with Debug::{to_repr}

///|
pub extend GenerationResult with ToJson::{to_json}
