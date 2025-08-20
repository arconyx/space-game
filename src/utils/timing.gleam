//// Utilities for monitoring performance

import gleam/int
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
