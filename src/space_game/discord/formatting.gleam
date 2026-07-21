import gleam/float
import gleam/int
import gleam/time/timestamp

/// Format a timestamp for a Discord message. Displays a relative time,
/// localised in the Discord client.
pub fn relative_timestamp(timestamp: timestamp.Timestamp) {
  "<t:"
  <> timestamp.to_unix_seconds(timestamp)
  |> float.truncate()
  |> int.to_string()
  <> ":R>"
}

/// Format a timestamp for a Discord message. Displays the full timestamp,
/// localised in the Discord client.
pub fn absolute_timestamp(timestamp: timestamp.Timestamp) -> String {
  "<t:"
  <> timestamp.to_unix_seconds(timestamp)
  |> float.truncate()
  |> int.to_string()
  <> ">"
}
