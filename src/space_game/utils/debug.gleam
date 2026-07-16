//// Utilities for debug logging and the like

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import logging

@external(erlang, "space_game_ffi", "now")
fn monotomic_time_ms() -> Int

/// Runs the supplied function and logs execution time
pub fn timed(label: String, with fun: fn() -> a) -> a {
  let start = monotomic_time_ms()
  let res = fun()
  let end = monotomic_time_ms() - start
  logging.log(
    logging.Debug,
    "[Timer] " <> label <> " " <> int.to_string(end) <> "ms",
  )
  res
}

pub fn json_decode_error_to_string(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "Unexpected end of input"
    json.UnexpectedByte(byte) -> "Unexpected byte '" <> byte <> "'"
    json.UnexpectedSequence(sequence) ->
      "Unexpected sequence '" <> sequence <> "'"
    json.UnableToDecode(decode_errors) ->
      "\n"
      <> string.join(
        list.map(decode_errors, fn(error) {
          let decode.DecodeError(expected:, found:, path:) = error
          "Expected '"
          <> expected
          <> "' but found '"
          <> found
          <> "' at '"
          <> string.join(path, with: ".")
          <> "'"
        }),
        with: "\n",
      )
  }
}
