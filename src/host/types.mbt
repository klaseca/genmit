///|
/// A process request produced by portable MoonBit orchestration.
#derive(Debug)
pub(all) struct ProcessRequest {
  command : String
  args : Array[String]
  cwd : String
  input : String
  timeout_ms : Int32
  maximum_output_bytes : Int32
}

///|
pub extend ProcessRequest with Debug::{to_repr}

///|
/// Raw process completion supplied by the platform host.
#derive(Debug)
pub(all) struct ProcessOutput {
  code : Int32
  stdout : String
  stderr : String
}

///|
pub extend ProcessOutput with Debug::{to_repr}
