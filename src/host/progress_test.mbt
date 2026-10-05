///|
fn progress_test_runner(request : @host.ProcessRequest) -> @host.ProcessOutput {
  let stdout = if request.command == "git" {
    match request.args[0] {
      "rev-parse" => "/repo\n"
      "branch" => "main\n"
      "log" => "chore: initial\n"
      "diff" =>
        if request.args.contains("--name-only") {
          "secret-name.txt\u{0000}"
        } else {
          "+secret-diff\n"
        }
      _ => ""
    }
  } else {
    "feat: generated message"
  }
  { code: 0, stdout, stderr: "secret-stderr", }
}

///|
test "model-less harness progress has a null model in JSON" {
  let event : @host.GenerationEvent = Started(provider="custom", model=None)
  assert_true(event.to_json() is { "type": "started", "model": Null, .. })
}

///|
async test "progress is metadata, ordered, and optional" {
  let config = @genmit.default_config()
  let provider = config.select_provider()
  let events : Array[@host.GenerationEvent] = []
  let result = @host.generate(
    config,
    provider,
    "/repo",
    request => progress_test_runner(request),
    on_event=event => events.push(event),
  )
  assert_eq(result.message, "feat: generated message")
  assert_true(
    events
    is [
      Started(provider=name, model~),
      CollectingChanges,
      ChangesCollected(files=1, diff_chars=13),
      RequestStarted(number=1, phase=GenerateMessage, input_chars~),
      RequestCompleted(number=1, duration_ms~),
      Completed(duration_ms=total),
    ] &&
    name == provider.name() &&
    model == provider.model() &&
    input_chars > 0 &&
    duration_ms >= 0 &&
    total >= duration_ms,
  )
  for event in events {
    let serialized = event.to_json().stringify()
    for
      secret in ["secret-name", "secret-diff", "secret-stderr", result.message] {
      assert_false(serialized.contains(secret))
    }
  }
  let quiet = @host.generate(config, provider, "/repo", request => {
    progress_test_runner(request)
  })
  assert_eq(quiet.message, result.message)
}

///|
async test "progress reports provider failure without success or response data" {
  let config = @genmit.default_config()
  let events : Array[@host.GenerationEvent] = []
  try
    @host.generate(
      config,
      config.select_provider(),
      "/repo",
      request => {
        if request.command == "git" {
          progress_test_runner(request)
        } else {
          { code: 1, stdout: "secret-response", stderr: "secret-error", }
        }
      },
      on_event=event => events.push(event),
    )
  catch {
    @genmit.GenmitError(message) =>
      assert_true(message.contains("secret-error"))
    error => raise error
  } noraise {
    _ => fail("expected provider failure")
  }
  assert_true(
    events
    is [
      Started(..),
      CollectingChanges,
      ChangesCollected(..),
      RequestStarted(..),
      RequestFailed(number=1, ..),
      Failed(..),
    ],
  )
  for event in events {
    assert_false(event.to_json().stringify().contains("secret"))
  }
}

///|
async test "generation deadline emits one failed terminal event" {
  let config = @genmit.Config::from_toml("[generation]\ntimeout_ms = 10")
  let events : Array[@host.GenerationEvent] = []
  try
    @host.generate(
      config,
      config.select_provider(),
      "/repo",
      request => {
        if request.command != "git" {
          @async.sleep(1000)
        }
        progress_test_runner(request)
      },
      on_event=event => events.push(event),
    )
  catch {
    @genmit.GenmitError(message) => assert_true(message.contains("timed out"))
    error => raise error
  } noraise {
    _ => fail("expected timeout")
  }
  assert_true(events is [.., RequestFailed(number=1, ..), Failed(..)])
}

///|
async test "external cancellation emits a cancelled terminal event" {
  let config = @genmit.default_config()
  let events : Array[@host.GenerationEvent] = []
  @async.with_task_group() <| group => {
    let task = group.spawn(
      () => {
        @host.generate(
          config,
          config.select_provider(),
          "/repo",
          request => {
            if request.command != "git" {
              @async.sleep(1000)
            }
            progress_test_runner(request)
          },
          on_event=event => events.push(event),
        )
      },
      allow_failure=true,
    )
    while !events.any(event => event is RequestStarted(..)) {
      @async.pause()
    }
    task.cancel()
    try task.wait() catch {
      error => assert_true(@async.is_cancellation_error(error))
    } noraise {
      _ => fail("expected cancellation")
    }
  }
  assert_true(events is [.., RequestFailed(number=1, ..), Cancelled(..)])
}

///|
async test "cancellation cleanup failure emits failed rather than cancelled" {
  let config = @genmit.default_config()
  let events : Array[@host.GenerationEvent] = []
  @async.with_task_group() <| group => {
    let task = group.spawn(
      () => {
        @host.generate(
          config,
          config.select_provider(),
          "/repo",
          request => {
            if request.command != "git" {
              fn fail_cleanup() -> Unit raise {
                raise @genmit.GenmitError("process cleanup failed")
              }
              errdefer fail_cleanup()
              @async.sleep(1000)
            }
            progress_test_runner(request)
          },
          on_event=event => events.push(event),
        )
      },
      allow_failure=true,
    )
    while !events.any(event => event is RequestStarted(..)) {
      @async.pause()
    }
    task.cancel()
    try task.wait() catch {
      @genmit.GenmitError(message) =>
        assert_eq(message, "process cleanup failed")
      error => raise error
    } noraise {
      _ => fail("expected cleanup failure")
    }
  }
  assert_true(events is [.., RequestFailed(number=1, ..), Failed(..)])
  assert_eq(events.filter(event => event is Failed(..)).length(), 1)
  assert_false(
    events.any(event => event is Cancelled(..) || event is Completed(..)),
  )
}
