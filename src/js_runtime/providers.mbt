///|
extern "js" fn providers_success(data : String) -> RuntimeResponse =
  #| (data) => ({ ok: true, value: JSON.parse(data) })

///|
/// List named providers from TOML or the shared defaults for host-side selection.
pub fn list_providers(input : String) -> RuntimeResponse {
  try {
    guard @json.parse(input) is Object(request) else {
      raise @genmit.GenmitError("provider list request must be an object")
    }

    let config = config_from_request(request)

    let selected = config.select_provider().name()

    let providers : Array[Json] = []

    for (name, kind) in config.provider_kinds() {
      providers.push({
        "name": name.to_json(),
        "kind": kind.to_json(),
        "selected": (name == selected).to_json(),
      })
    }

    providers_success(providers.to_json().stringify())
  } catch {
    @genmit.GenmitError(message) => api_error(message)
    error => api_error(error.to_string())
  }
}
