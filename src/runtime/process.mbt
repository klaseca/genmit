///|
/// Read incrementally so a child or server cannot allocate unbounded memory.
async fn read_bounded(reader : &@io.Reader, maximum : Int) -> &@io.Data {
  let buffer = @buffer.Buffer()

  while reader.read_some(max_len=8192) is Some(chunk) {
    if buffer.length() + chunk.length() > maximum {
      raise @genmit.GenmitError("output exceeds the \{maximum} byte limit")
    }

    buffer.write_bytes(chunk)
  }

  buffer.to_bytes()
}

///|
async fn collect_process(
  command : String,
  args : Array[String],
  cwd : String,
  input : String,
  timeout_ms~ : Int,
  maximum~ : Int,
) -> (Int, String, String) {
  @async.with_timeout(timeout_ms, () => {
    @async.with_task_group() <| group => {
      let (stdin, writer) = @process.write_to_process()

      let (reader, stdout) = @process.read_from_process()

      let (error_reader, stderr) = @process.read_from_process()

      let runner = group.spawn(() => {
        @process.run(
          command,
          args,
          stdin~,
          stdout~,
          stderr~,
          cwd~,
          no_console_window=true,
        )
      })

      let output = group.spawn(() => {
        defer reader.close()

        read_bounded(reader, maximum).text()
      })

      let errors = group.spawn(() => {
        defer error_reader.close()

        read_bounded(error_reader, 1024 * 1024).text()
      })

      let input_error = group.spawn(() => {
        defer writer.close()

        try writer.write(input) catch {
          error => Some(error)
        } noraise {
          _ => None
        }
      })

      let code = runner.wait()

      let output = output.wait()

      let errors = errors.wait()

      // An early process failure may close stdin while the prompt is still
      // being written; its exit code and stderr are the useful diagnostics.
      if input_error.wait() is Some(error) && code == 0 {
        raise error
      }

      (code, output, errors)
    }
  }) catch {
    error if @async.is_cancellation_error(error) => raise error
    error =>
      raise @genmit.GenmitError(
        "failed to run command '\{command}': \{repr(error)}",
      )
  }
}

///|
async fn run_host_process(
  request : @host.ProcessRequest,
) -> @host.ProcessOutput {
  let (code, stdout, stderr) = collect_process(
    request.command,
    request.args,
    request.cwd,
    request.input,
    timeout_ms=request.timeout_ms,
    maximum=request.maximum_output_bytes,
  )

  { code, stdout, stderr, }
}
