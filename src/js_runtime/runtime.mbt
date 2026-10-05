///|
/// Process capability supplied by the JavaScript host.
#external
pub type ProcessRunner

///|
/// Optional JavaScript subscriber receiving plain progress metadata objects.
#external
pub type ProgressListener

///|
extern "js" fn ProgressListener::emit(self : Self, event : String) -> Unit =
  #| (listener, event) => listener?.(JSON.parse(event))

///|
/// A process result returned by the JavaScript host.
#external
priv type JsProcessOutput

///|
/// Per-generation transport state preserves rejection identity before JS errors
/// are converted to MoonBit errors. Requests are executed sequentially.
#external
priv type GenerationControl

///|
extern "js" fn GenerationControl::GenerationControl(
  signal : @js_async.AbortSignal,
  timeout_ms : Int,
) -> GenerationControl =
  #| (signal, timeout_ms) => {
  #|   const timeout = AbortSignal.timeout(timeout_ms)
  #|
  #|   return {
  #|     signal: AbortSignal.any([signal, timeout]),
  #|     timeout,
  #|     processFailed: false,
  #|     processCancelled: false,
  #|     processError: undefined,
  #|   }
  #| }

///|
extern "js" fn GenerationControl::timed_out(self : Self) -> Bool =
  #| c => c.signal.aborted && c.signal.reason === c.timeout.reason && c.timeout.aborted

///|
extern "js" fn GenerationControl::process_failed(self : Self) -> Bool =
  #| c => c.processFailed

///|
extern "js" fn GenerationControl::process_cancelled(self : Self) -> Bool =
  #| c => c.processCancelled

///|
extern "js" fn GenerationControl::process_error(self : Self) -> String =
  #| c => String(c.processError)

///|
extern "js" fn ProcessRunner::run(
  self : ProcessRunner,
  command : String,
  args : FixedArray[String],
  cwd : String,
  input : String,
  timeout_ms : Int,
  maximum_output_bytes : Int,
  control : GenerationControl,
) -> @js_async.Promise[JsProcessOutput] =
  #| async (runner, command, args, cwd, input, timeout_ms, maximum_output_bytes, control) => {
  #|   try {
  #|     return await runner(
  #|       {
  #|         command,
  #|         args,
  #|         cwd,
  #|         input,
  #|         timeoutMs: timeout_ms,
  #|         maximumOutputBytes: maximum_output_bytes,
  #|       },
  #|       control.signal,
  #|     )
  #|   } catch (error) {
  #|     control.processCancelled = control.signal.aborted && error === control.signal.reason
  #|     control.processFailed = !control.processCancelled
  #|     control.processError = error
  #|     throw error
  #|   }
  #| }

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
/// A plain JavaScript response consumed by the extension.
#external
pub type RuntimeResponse

///|
extern "js" fn api_error(message : String) -> RuntimeResponse =
  #| (message) => ({ ok: false, error: message })

///|
extern "js" fn api_cancelled() -> RuntimeResponse =
  #| () => ({ ok: false, cancelled: true, error: "Generation cancelled" })

///|
extern "js" fn api_success(
  protocol_version : Int,
  message : String,
  provider : String,
  files : FixedArray[String],
) -> RuntimeResponse =
  #| (protocol_version, message, provider, files) => ({
  #|   ok: true,
  #|   value: { protocol_version, message, provider, files, },
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
  control : GenerationControl,
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
      control,
    )
    .wait()
  { code: output.code(), stdout: output.stdout(), stderr: output.stderr(), }
}

///|
async fn generate_response(
  input : String,
  runner : ProcessRunner,
  signal : @js_async.AbortSignal,
  on_event : ProgressListener,
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

    let control = GenerationControl(signal, config.generation_timeout_ms)

    let mut terminal_event : @host.GenerationEvent? = None

    let result = @host.generate(
      config,
      provider,
      root,
      process_request => run_process(runner, control, process_request),
      on_event=event => {
        // Classify failed/cancelled outcomes using transport identity below.
        if event is Failed(..) || event is Cancelled(..) {
          terminal_event = Some(event)
          return
        }
        on_event.emit(event.to_json().stringify())
      },
    ) catch {
      error => {
        let cancelled = !control.process_failed() &&
          !control.timed_out() &&
          (control.process_cancelled() || @async.is_cancellation_error(error))
        if terminal_event is Some(event) {
          let event = match event {
            Failed(duration_ms~) | Cancelled(duration_ms~) =>
              if cancelled {
                @host.GenerationEvent::Cancelled(duration_ms~)
              } else {
                @host.GenerationEvent::Failed(duration_ms~)
              }
            _ => event
          }
          on_event.emit(event.to_json().stringify())
        }
        if cancelled {
          return api_cancelled()
        }
        if control.process_failed() && control.timed_out() {
          let details = control.process_error()
          return api_error(
            "generation timed out after \{config.generation_timeout_ms} ms; process failed during shutdown: \{details}",
          )
        }
        if control.timed_out() {
          raise @genmit.GenmitError(
            "generation timed out after \{config.generation_timeout_ms} ms",
          )
        } else {
          raise error
        }
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
extern "js" fn generate_with_progress(
  input : String,
  runner : ProcessRunner,
  signal : @js_async.AbortSignal,
  on_event : ProgressListener,
  run : (String, ProcessRunner, @js_async.AbortSignal, ProgressListener) -> @js_async.Promise[
    RuntimeResponse,
  ],
) -> @js_async.Promise[RuntimeResponse] =
  #| async (input, runner, signal, onEvent, run) => {
  #|   signal.throwIfAborted()
  #|
  #|   const progressFailure = new AbortController()
  #|
  #|   const generationSignal = AbortSignal.any([signal, progressFailure.signal])
  #|
  #|   const listener = onEvent == null ? undefined : event => {
  #|     if (progressFailure.signal.aborted) {
  #|       return
  #|     }
  #|
  #|     try {
  #|       onEvent(event)
  #|     } catch (error) {
  #|       // Cancel safely across FFI; return the original error after cleanup.
  #|       progressFailure.abort(error)
  #|     }
  #|   }
  #|
  #|   const response = await run(input, runner, generationSignal, listener)
  #|
  #|   if (progressFailure.signal.aborted) {
  #|     if (!response.ok && !response.cancelled) {
  #|       const failure = new Error(response.error)
  #|
  #|       throw new AggregateError(
  #|         [failure, progressFailure.signal.reason],
  #|         `${failure.message}; progress listener failed: ${String(progressFailure.signal.reason)}`,
  #|       )
  #|     }
  #|
  #|     throw progressFailure.signal.reason
  #|   }
  #|
  #|   return response
  #| }

///|
/// Generate a commit message while delegating process creation to JavaScript.
/// JavaScript callers may omit the fourth argument to disable progress.
pub fn generate(
  input : String,
  runner : ProcessRunner,
  signal : @js_async.AbortSignal,
  on_event : ProgressListener,
) -> @js_async.Promise[RuntimeResponse] {
  generate_with_progress(input, runner, signal, on_event, (
    input,
    runner,
    signal,
    on_event,
  ) => {
    @js_async.Promise::from_async(
      () => generate_response(input, runner, signal, on_event),
      abort_signal=signal,
    )
  })
}
