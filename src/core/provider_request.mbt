///|
/// Credential location; the host reads the secret and applies it to the header.
pub struct RequestAuth {
  env : String
  header : String
  prefix : String
} derive(Debug)

///|
pub extend RequestAuth with Debug::{to_repr}

///|
/// HTTP data executed uniformly by the host.
pub struct HttpTransport {
  endpoint : String
  headers : Map[String, String]
  auth : RequestAuth
  body : Json
} derive(Debug)

///|
pub extend HttpTransport with Debug::{to_repr}

///|
/// A prepared HTTP request that owns the response semantics of its API.
pub trait HttpRequest {
  fn transport(Self) -> HttpTransport
  fn extract_response(Self, String) -> String raise GenmitError
}

///|
/// A provider request prepared for either a command-line harness or HTTP.
pub(all) enum ProviderRequest {
  Process(executable~ : String, args~ : Array[String], input~ : String)
  Http(&HttpRequest)
}

///|
fn prepare_harness_request(
  harness : HarnessConfig,
  provider : HarnessProviderConfig,
  input : String,
) -> ProviderRequest {
  let args = harness.args.copy()

  for key, parameter in harness.parameters {
    if provider.config.get(key) is Some(value) && value != "" {
      for argument in parameter.args {
        args.push(argument.replace_all(old="${value}", new=value))
      }
    }
  }

  args.append(harness.tail_args)

  Process(executable=harness.executable, args~, input~)
}

///|
/// Prepare a provider call without accessing credentials, processes, or network.
pub fn SelectedProvider::prepare_request(
  self : SelectedProvider,
  prompt : Prompt,
) -> ProviderRequest {
  match self.data {
    Harness(harness, provider) =>
      prepare_harness_request(harness, provider, prompt.to_text())
    Api(provider, config) => Http(provider.prepare_request(config, prompt))
  }
}

///|
/// Return the selected provider name.
pub fn SelectedProvider::name(self : SelectedProvider) -> String {
  self.name
}

///|
/// The configured model, when the harness declares a model parameter.
pub fn SelectedProvider::model(self : SelectedProvider) -> String? {
  match self.data {
    Harness(_, provider) => provider.config.get("model")
    Api(_, config) => Some(config.model)
  }
}
