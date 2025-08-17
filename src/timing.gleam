import gleam/int
import logging

@external(erlang, "space_game_ffi", "now")
pub fn monotomic_time_ms() -> Int

/// Prints timing information of inner function
pub fn timed(label: String, with fun: fn() -> a) -> a {
  let start = monotomic_time_ms()
  let res = fun()
  logging.log(
    logging.Debug,
    "[Timer] "
      <> label
      <> " "
      <> int.to_string(monotomic_time_ms() - start)
      <> "ms",
  )
  res
}
