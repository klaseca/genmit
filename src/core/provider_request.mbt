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
/// Prepare a provider call without accessing credentials, processes, or network.
pub fn SelectedProvider::prepare_request(
  self : SelectedProvider,
  prompt : Prompt,
) -> ProviderRequest {
  match self.data {
    Harness(executable~, args~, model=_) =>
      Process(executable~, args=args.copy(), input=prompt.to_text())
    Api(provider, config) => Http(provider.prepare_request(config, prompt))
  }
}

///|
/// Return the selected provider name.
pub fn SelectedProvider::name(self : SelectedProvider) -> String {
  self.name
}

///|
/// Maximum prepared input size allowed for this provider, in characters.
pub fn SelectedProvider::max_input_chars(self : SelectedProvider) -> Int {
  self.settings.max_input_chars
}

///|
/// The explicitly configured model, when known. Harnesses use the optional
/// logical parameter named "model"; no model is inferred from other arguments.
pub fn SelectedProvider::model(self : SelectedProvider) -> String? {
  match self.data {
    Harness(executable=_, args=_, model~) => model
    Api(_, config) => Some(config.model)
  }
}
