///|
/// Process capability supplied by the JavaScript host.
#external
pub type ProcessRunner

///|
/// A process result returned by the JavaScript host.
#external
priv type JsProcessOutput

///|
extern "js" fn ProcessRunner::run(
  self : ProcessRunner,
  command : String,
  args : FixedArray[String],
  cwd : String,
  input : String,
  timeout_ms : Int,
  maximum_output_bytes : Int,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[JsProcessOutput] =
  #| (runner, command, args, cwd, input, timeout_ms, maximum_output_bytes, signal) =>
  #|   runner(
  #|     {
  #|       command,
  #|       args,
  #|       cwd,
  #|       input,
  #|       timeoutMs: timeout_ms,
  #|       maximumOutputBytes: maximum_output_bytes,
  #|     },
  #|     signal,
  #|   )

///|
extern "js" fn JsProcessOutput::code(self : Self) -> Int =
  #| (output) => output.code

///|
extern "js" fn JsProcessOutput::stdout(self : Self) -> String =
  #| (output) => output.stdout

///|
extern "js" fn JsProcessOutput::stderr(self : Self) -> String =
  #| (output) => output.stderr

///|
extern "js" fn @js_async.AbortSignal::with_timeout(
  self : @js_async.AbortSignal,
  timeout_ms : Int,
) -> @js_async.AbortSignal =
  #| (signal, timeout_ms) => AbortSignal.any([
  #|   signal,
  #|   AbortSignal.timeout(timeout_ms),
  #| ])

///|
extern "js" fn @js_async.AbortSignal::timed_out(
  self : @js_async.AbortSignal,
) -> Bool =
  #| (signal) => signal.aborted && signal.reason?.name === "TimeoutError"

///|
/// A plain JavaScript response consumed by the extension.
#external
pub type RuntimeResponse

///|
extern "js" fn api_error(message : String) -> RuntimeResponse =
  #| (message) => ({ ok: false, error: message })

///|
extern "js" fn api_success(
  protocol_version : Int,
  message : String,
  provider : String,
  files : FixedArray[String],
) -> RuntimeResponse =
  #| (protocol_version, message, provider, files) => ({
  #|   ok: true,
  #|   value: { protocol_version, message, provider, files },
  #| })

///|
fn require_string(
  object : Map[String, Json],
  key : String,
) -> String raise @genmit.GenmitError {
  match object.get(key) {
    Some(String(value)) => value
    _ => raise GenmitError("JavaScript request field '\{key}' must be a string")
  }
}

///|
fn config_from_request(
  request : Map[String, Json],
) -> @genmit.Config raise @genmit.GenmitError {
  match request.get("config_source") {
    None => @genmit.default_config()
    Some(String(source)) => @genmit.Config::from_toml(source)
    _ =>
      raise GenmitError(
        "JavaScript request field 'config_source' must be a string",
      )
  }
}

///|
async fn run_process(
  runner : ProcessRunner,
  signal : @js_async.AbortSignal,
  request : @host.ProcessRequest,
) -> @host.ProcessOutput {
  let output = runner
    .run(
      request.command,
      FixedArray::from_array(request.args),
      request.cwd,
      request.input,
      request.timeout_ms,
      request.maximum_output_bytes,
      signal,
    )
    .wait()
  { code: output.code(), stdout: output.stdout(), stderr: output.stderr(), }
}

///|
async fn generate_response(
  input : String,
  runner : ProcessRunner,
  signal : @js_async.AbortSignal,
) -> RuntimeResponse {
  try {
    let json = @json.parse(input) catch {
      error =>
        raise @genmit.GenmitError(
          "JavaScript request contains invalid JSON: \{error}",
        )
    }

    guard json is Object(request) else {
      raise @genmit.GenmitError("JavaScript request must be a JSON object")
    }

    let root = require_string(request, "root")

    let config = config_from_request(request)

    let provider = match request.get("provider") {
      None => config.select_provider()
      Some(String(name)) => config.select_provider(provider=name)
      _ =>
        raise @genmit.GenmitError(
          "JavaScript request field 'provider' must be a string",
        )
    }

    let generation_signal = signal.with_timeout(config.generation_timeout_ms)

    let result = @host.generate(config, provider, root, process_request => {
      run_process(runner, generation_signal, process_request)
    }) catch {
      error =>
        if generation_signal.timed_out() {
          raise @genmit.GenmitError(
            "generation timed out after \{config.generation_timeout_ms} ms",
          )
        } else {
          raise error
        }
    }

    api_success(
      result.protocol_version,
      result.message,
      result.provider,
      FixedArray::from_array(result.files),
    )
  } catch {
    @genmit.GenmitError(message) => api_error(message)
    error => raise error
  }
}

///|
/// Generate a commit message while delegating process creation to JavaScript.
pub fn generate(
  input : String,
  runner : ProcessRunner,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[RuntimeResponse] {
  @js_async.Promise::from_async(
    () => generate_response(input, runner, signal),
    abort_signal=signal,
  )
}
