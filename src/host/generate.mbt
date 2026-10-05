///|
/// Build a direct prompt preview after collecting staged Git state.
pub async fn prepare_prompt(
  config : @genmit.Config,
  root : String,
  runner : async (ProcessRequest) -> ProcessOutput,
) -> String {
  let context = collect_git_context(root, runner)

  @genmit.build_prompt(config, context).to_text()
}

///|
let initial_diff_chunk_chars = 12000

///|
let maximum_provider_request_chars = 32000

///|
priv struct ProviderCallBudget {
  maximum : Int
  mut used : Int
  on_event : (GenerationEvent) -> Unit
}

///|
fn ProviderCallBudget::ProviderCallBudget(
  maximum : Int,
  on_event : (GenerationEvent) -> Unit,
) -> ProviderCallBudget {
  { maximum, used: 0, on_event, }
}

///|
fn ProviderCallBudget::ensure_available(
  self : ProviderCallBudget,
  required : Int,
) -> Unit raise @genmit.GenmitError {
  if self.used + required > self.maximum {
    raise GenmitError(
      "generation requires at least \{self.used + required} provider calls, but generation.max_provider_calls is \{self.maximum}; split the staged changes or increase the limit",
    )
  }
}

///|
fn ProviderCallBudget::consume(
  self : ProviderCallBudget,
) -> Unit raise @genmit.GenmitError {
  if self.used >= self.maximum {
    raise GenmitError(
      "generation exceeded generation.max_provider_calls (\{self.maximum}); split the staged changes or increase the limit",
    )
  }

  self.used += 1
}

///|
async fn ProviderCallBudget::call(
  self : ProviderCallBudget,
  provider : @genmit.SelectedProvider,
  prompt : @genmit.Prompt,
  root : String,
  runner : async (ProcessRequest) -> ProcessOutput,
  phase : GenerationPhase,
) -> String {
  self.consume()
  let number = self.used
  let started = @async.now()
  (self.on_event)(
    RequestStarted(
      number~,
      phase~,
      input_chars=provider_request_chars(provider, prompt),
    ),
  )
  errdefer (self.on_event)(
    RequestFailed(number~, duration_ms=elapsed_ms(started)),
  )
  let response = call_provider(provider, prompt, root, runner)
  (self.on_event)(RequestCompleted(number~, duration_ms=elapsed_ms(started)))
  response
}

///|
fn provider_request_chars(
  provider : @genmit.SelectedProvider,
  prompt : @genmit.Prompt,
) -> Int {
  match provider.prepare_request(prompt) {
    Process(input~, ..) => input.char_length()
    Http(request) => request.transport().body.stringify().char_length()
  }
}

///|
fn validate_summary(raw : String) -> String raise @genmit.GenmitError {
  let summary = raw.trim().to_owned()

  if summary == "" {
    raise GenmitError("provider returned an empty staged-change summary")
  }

  if summary.char_length() > 8000 {
    raise GenmitError(
      "provider returned a staged-change summary longer than 8000 characters",
    )
  }

  summary
}

///|
fn group_summaries(
  provider : @genmit.SelectedProvider,
  summaries : Array[String],
) -> Array[Array[String]] {
  let groups : Array[Array[String]] = []
  let mut current : Array[String] = []

  for summary in summaries {
    let candidate = current.copy()

    candidate.push(summary)

    let prompt = @genmit.build_summary_reduction_prompt(candidate)

    if current.length() > 0 &&
      provider_request_chars(provider, prompt) > maximum_provider_request_chars {
      groups.push(current)
      current = []
    }

    current.push(summary)
  }

  if current.length() > 0 {
    groups.push(current)
  }

  groups
}

///|
fn diff_chunks_for_provider(
  provider : @genmit.SelectedProvider,
  diff : String,
) -> Array[@genmit.DiffChunk] raise @genmit.GenmitError {
  diff_chunks_for_provider_at(provider, diff, initial_diff_chunk_chars)
}

///|
fn diff_chunks_for_provider_at(
  provider : @genmit.SelectedProvider,
  diff : String,
  maximum : Int,
) -> Array[@genmit.DiffChunk] raise @genmit.GenmitError {
  let chunks = @genmit.split_diff(diff, maximum)
  let mut fit = true

  for index in 0..<chunks.length() {
    let prompt = @genmit.build_diff_summary_prompt(
      chunks[index],
      index + 1,
      chunks.length(),
    )

    if provider_request_chars(provider, prompt) > maximum_provider_request_chars {
      fit = false
      break
    }
  }

  if fit {
    return chunks
  }

  if maximum == 1 {
    raise GenmitError(
      "provider request overhead exceeds the internal input budget",
    )
  }

  diff_chunks_for_provider_at(provider, diff, (maximum / 2).max(1))
}

///|
async fn summarize_diff(
  provider : @genmit.SelectedProvider,
  config : @genmit.Config,
  context : @genmit.GitContext,
  budget : ProviderCallBudget,
  runner : async (ProcessRequest) -> ProcessOutput,
) -> Array[String] {
  if provider_request_chars(
      provider,
      @genmit.build_prompt_from_summaries(config, context, []),
    ) >
    maximum_provider_request_chars {
    raise @genmit.GenmitError(
      "final request metadata exceeds the provider request limit; stage fewer files or shorten the configured instructions",
    )
  }

  let chunks = diff_chunks_for_provider(provider, context.diff)
  let summaries = []

  budget.ensure_available(chunks.length() + 1)

  for index in 0..<chunks.length() {
    let prompt = @genmit.build_diff_summary_prompt(
      chunks[index],
      index + 1,
      chunks.length(),
    )

    summaries.push(
      validate_summary(
        budget.call(
          provider,
          prompt,
          context.root,
          runner,
          Summarize(part=index + 1, total=chunks.length()),
        ),
      ),
    )
  }

  let mut reduced = summaries
  let mut rounds = 0

  while provider_request_chars(
          provider,
          @genmit.build_prompt_from_summaries(config, context, reduced),
        ) >
        maximum_provider_request_chars {
    if rounds >= 12 {
      raise @genmit.GenmitError(
        "provider could not condense the staged diff into a final request",
      )
    }

    let next = []

    let groups = group_summaries(provider, reduced)
    for index, group in groups {
      let prompt = @genmit.build_summary_reduction_prompt(group)

      next.push(
        validate_summary(
          budget.call(
            provider,
            prompt,
            context.root,
            runner,
            Reduce(round=rounds + 1, part=index + 1, total=groups.length()),
          ),
        ),
      )
    }

    reduced = next
    rounds += 1
  }

  reduced
}

///|
async fn generate_within_budget(
  config : @genmit.Config,
  provider : @genmit.SelectedProvider,
  root : String,
  runner : async (ProcessRequest) -> ProcessOutput,
  on_event : (GenerationEvent) -> Unit,
) -> @genmit.GenerationResult {
  on_event(CollectingChanges)
  let context = collect_git_context(root, runner)
  on_event(
    ChangesCollected(
      files=context.staged_files.length(),
      diff_chars=context.diff.char_length(),
    ),
  )

  let budget = ProviderCallBudget(config.max_provider_calls, on_event)

  let direct_prompt = @genmit.build_prompt(config, context)

  let prompt = if provider_request_chars(provider, direct_prompt) <=
    maximum_provider_request_chars {
    direct_prompt
  } else {
    let summaries = summarize_diff(provider, config, context, budget, runner)
    @genmit.build_prompt_from_summaries(config, context, summaries)
  }

  let raw_message = budget.call(
    provider,
    prompt,
    context.root,
    runner,
    GenerateMessage,
  )

  let message = config.normalize_message(raw_message)

  {
    protocol_version: 1,
    message,
    provider: provider.name(),
    files: context.staged_files,
  }
}

///|
/// Generate a commit message while delegating process creation to the host.
pub async fn generate(
  config : @genmit.Config,
  provider : @genmit.SelectedProvider,
  root : String,
  runner : async (ProcessRequest) -> ProcessOutput,
  on_event? : (GenerationEvent) -> Unit = _ => (),
) -> @genmit.GenerationResult {
  let started = @async.now()
  let mut failed = false
  errdefer on_event(
    if failed {
      Failed(duration_ms=elapsed_ms(started))
    } else {
      Cancelled(duration_ms=elapsed_ms(started))
    },
  )
  let result = @async.with_timeout(
    config.generation_timeout_ms,
    () => {
      on_event(Started(provider=provider.name(), model=provider.model()))
      // A subscriber may cancel synchronously. Observe cancellation before
      // invoking Git, with the timeout task group already established.
      @async.pause()
      generate_within_budget(config, provider, root, runner, on_event)
    },
    error=@genmit.GenmitError(
      "generation timed out after \{config.generation_timeout_ms} ms",
    ),
  ) catch {
    error if !@async.is_cancellation_error(error) => {
      failed = true
      raise error
    }
    error => raise error
  }
  on_event(Completed(duration_ms=elapsed_ms(started)))
  result
}
