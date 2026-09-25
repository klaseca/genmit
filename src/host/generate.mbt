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
}

///|
fn ProviderCallBudget::ProviderCallBudget(maximum : Int) -> ProviderCallBudget {
  { maximum, used: 0, }
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

    budget.consume()
    summaries.push(
      validate_summary(call_provider(provider, prompt, context.root, runner)),
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

    for group in group_summaries(provider, reduced) {
      let prompt = @genmit.build_summary_reduction_prompt(group)

      budget.consume()
      next.push(
        validate_summary(call_provider(provider, prompt, context.root, runner)),
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
) -> @genmit.GenerationResult {
  let context = collect_git_context(root, runner)

  let budget = ProviderCallBudget(config.max_provider_calls)

  let direct_prompt = @genmit.build_prompt(config, context)

  let prompt = if provider_request_chars(provider, direct_prompt) <=
    maximum_provider_request_chars {
    direct_prompt
  } else {
    let summaries = summarize_diff(provider, config, context, budget, runner)
    @genmit.build_prompt_from_summaries(config, context, summaries)
  }

  budget.consume()
  let raw_message = call_provider(provider, prompt, context.root, runner)

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
) -> @genmit.GenerationResult {
  @async.with_timeout(
    config.generation_timeout_ms,
    () => generate_within_budget(config, provider, root, runner),
    error=@genmit.GenmitError(
      "generation timed out after \{config.generation_timeout_ms} ms",
    ),
  )
}
