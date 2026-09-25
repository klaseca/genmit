///|
/// Invoke the platform process capability while keeping cancellation intact
/// and translating host failures into genmit's public error type.
async fn execute_process(
  request : ProcessRequest,
  runner : async (ProcessRequest) -> ProcessOutput,
) -> ProcessOutput {
  runner(request) catch {
    error if @async.is_being_cancelled() => raise error
    @genmit.GenmitError(message) => raise @genmit.GenmitError(message)
    error =>
      raise @genmit.GenmitError(
        "failed to run command '\{request.command}': \{error.to_string()}",
      )
  }
}
