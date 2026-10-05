///|
/// The purpose of a provider request, independent of its transport.
pub(all) enum GenerationPhase {
  Summarize(part~ : Int, total~ : Int)
  Reduce(round~ : Int, part~ : Int, total~ : Int)
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
  ChangesCollected(files~ : Int, diff_chars~ : Int)
  RequestStarted(number~ : Int, phase~ : GenerationPhase, input_chars~ : Int)
  RequestCompleted(number~ : Int, duration_ms~ : Int)
  RequestFailed(number~ : Int, duration_ms~ : Int)
  Completed(duration_ms~ : Int)
  Failed(duration_ms~ : Int)
  Cancelled(duration_ms~ : Int)
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
  let fields : Map[String, Json] = { "message": self.description().to_json() }
  let kind = match self {
    Started(provider~, model~) => {
      fields["provider"] = provider.to_json()
      fields["model"] = match model {
        Some(value) => value.to_json()
        None => Json::null()
      }
      "started"
    }
    CollectingChanges => "collecting_changes"
    ChangesCollected(files~, diff_chars~) => {
      fields["files"] = files.to_json()
      fields["diff_chars"] = diff_chars.to_json()
      "changes_collected"
    }
    RequestStarted(number~, phase~, input_chars~) => {
      fields["number"] = number.to_json()
      fields["input_chars"] = input_chars.to_json()
      fields["stage"] = phase.description().to_json()
      match phase {
        Summarize(part~, total~) => {
          fields["phase"] = "summarize".to_json()
          fields["part"] = part.to_json()
          fields["total"] = total.to_json()
        }
        Reduce(round~, part~, total~) => {
          fields["phase"] = "reduce".to_json()
          fields["round"] = round.to_json()
          fields["part"] = part.to_json()
          fields["total"] = total.to_json()
        }
        GenerateMessage => fields["phase"] = "generate_message".to_json()
      }
      "request_started"
    }
    RequestCompleted(number~, duration_ms~) => {
      fields["number"] = number.to_json()
      fields["duration_ms"] = duration_ms.to_json()
      "request_completed"
    }
    RequestFailed(number~, duration_ms~) => {
      fields["number"] = number.to_json()
      fields["duration_ms"] = duration_ms.to_json()
      "request_failed"
    }
    Completed(duration_ms~) => {
      fields["duration_ms"] = duration_ms.to_json()
      "completed"
    }
    Failed(duration_ms~) => {
      fields["duration_ms"] = duration_ms.to_json()
      "failed"
    }
    Cancelled(duration_ms~) => {
      fields["duration_ms"] = duration_ms.to_json()
      "cancelled"
    }
  }
  fields["type"] = kind.to_json()
  Json::object(fields)
}

///|
pub extend GenerationEvent with ToJson::{to_json}

///|
fn elapsed_ms(started : Int64) -> Int {
  (@async.now() - started).max(0).to_int()
}
