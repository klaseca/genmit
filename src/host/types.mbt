///|
/// A process request produced by portable MoonBit orchestration.
pub(all) struct ProcessRequest {
  command : String
  args : Array[String]
  cwd : String
  input : String
  timeout_ms : Int
  maximum_output_bytes : Int
} derive(Debug)

///|
pub extend ProcessRequest with Debug::{to_repr}

///|
/// Raw process completion supplied by the platform host.
pub(all) struct ProcessOutput {
  code : Int
  stdout : String
  stderr : String
} derive(Debug)

///|
pub extend ProcessOutput with Debug::{to_repr}
