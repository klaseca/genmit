///|
/// The purpose of a provider request, independent of its transport.
pub(all) enum GenerationPhase {
  Summarize(part~ : Int32, total~ : Int32)
  Reduce(round~ : Int32, part~ : Int32, total~ : Int32)
  GenerateMessage
} derive(Debug, Eq)

///|
pub extend GenerationPhase with Debug::{to_repr}

///|
pub extend GenerationPhase with Eq::{equal, not_equal}

///|
pub fn GenerationPhase::description(self : GenerationPhase) -> String {
  match self {
    Summarize(part~, total~) => "Summarizing part \{part}/\{total}"
    Reduce(round~, part~, total~) =>
      "Reducing summaries, round \{round}, group \{part}/\{total}"
    GenerateMessage => "Generating commit message"
  }
}

///|
/// Progress metadata only: events never contain prompts, diffs, responses,
/// credentials, command arguments, or provider stderr. Callbacks are synchronous
/// and should return promptly. Each generation has its own callback.
pub(all) enum GenerationEvent {
  Started(provider~ : String, model~ : String?)
  CollectingChanges
  ChangesCollected(files~ : Int32, diff_chars~ : Int32)
  RequestStarted(
    number~ : Int32,
    phase~ : GenerationPhase,
    input_chars~ : Int32
  )
  RequestCompleted(number~ : Int32, duration_ms~ : Int32)
  RequestFailed(number~ : Int32, duration_ms~ : Int32)
  Completed(duration_ms~ : Int32)
  Failed(duration_ms~ : Int32)
  Cancelled(duration_ms~ : Int32)
} derive(Debug, Eq)

///|
pub extend GenerationEvent with Debug::{to_repr}

///|
pub extend GenerationEvent with Eq::{equal, not_equal}

///|
/// A common description for human-readable frontend logs.
pub fn GenerationEvent::description(self : GenerationEvent) -> String {
  match self {
    Started(provider~, model~) =>
      match model {
        Some(model) => "Started generation with \{provider} (\{model})"
        None => "Started generation with \{provider}"
      }
    CollectingChanges => "Collecting staged changes"
    ChangesCollected(files~, diff_chars~) =>
      "Collected \{files} staged files, \{diff_chars} diff characters"
    RequestStarted(number~, phase~, input_chars~) =>
      "Request \{number}: \{phase.description()} (\{input_chars} input characters)"
    RequestCompleted(number~, duration_ms~) =>
      "Request \{number} completed in \{duration_ms} ms"
    RequestFailed(number~, duration_ms~) =>
      "Request \{number} did not complete after \{duration_ms} ms"
    Completed(duration_ms~) => "Generation completed in \{duration_ms} ms"
    Failed(duration_ms~) => "Generation failed after \{duration_ms} ms"
    Cancelled(duration_ms~) => "Generation cancelled after \{duration_ms} ms"
  }
}

///|
impl ToJson for GenerationEvent with fn to_json(self) {
  let fields : Map[String, Json] = { "message": Json(self.description()) }
  let kind = match self {
    Started(provider~, model~) => {
      fields["provider"] = Json(provider)
      fields["model"] = match model {
        Some(value) => Json(value)
        None => Json::null()
      }
      "started"
    }
    CollectingChanges => "collecting_changes"
    ChangesCollected(files~, diff_chars~) => {
      fields["files"] = Json(files)
      fields["diff_chars"] = Json(diff_chars)
      "changes_collected"
    }
    RequestStarted(number~, phase~, input_chars~) => {
      fields["number"] = Json(number)
      fields["input_chars"] = Json(input_chars)
      fields["stage"] = Json(phase.description())
      match phase {
        Summarize(part~, total~) => {
          fields["phase"] = Json("summarize")
          fields["part"] = Json(part)
          fields["total"] = Json(total)
        }
        Reduce(round~, part~, total~) => {
          fields["phase"] = Json("reduce")
          fields["round"] = Json(round)
          fields["part"] = Json(part)
          fields["total"] = Json(total)
        }
        GenerateMessage => fields["phase"] = Json("generate_message")
      }
      "request_started"
    }
    RequestCompleted(number~, duration_ms~) => {
      fields["number"] = Json(number)
      fields["duration_ms"] = Json(duration_ms)
      "request_completed"
    }
    RequestFailed(number~, duration_ms~) => {
      fields["number"] = Json(number)
      fields["duration_ms"] = Json(duration_ms)
      "request_failed"
    }
    Completed(duration_ms~) => {
      fields["duration_ms"] = Json(duration_ms)
      "completed"
    }
    Failed(duration_ms~) => {
      fields["duration_ms"] = Json(duration_ms)
      "failed"
    }
    Cancelled(duration_ms~) => {
      fields["duration_ms"] = Json(duration_ms)
      "cancelled"
    }
  }
  fields["type"] = Json(kind)
  Json::object(fields)
}

///|
pub extend GenerationEvent with ToJson::{to_json}

///|
fn elapsed_ms(started : Int64) -> Int32 {
  (@async.now() - started).max(0).to_int()
}
