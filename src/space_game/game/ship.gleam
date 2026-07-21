import gleam/float
import gleam/int
import gleam/time/duration
import space_game/storage.{type Ship, type Waypoint}

// intended for debugging use by increasing travel times
const global_speed_multiplier: Int = 1

fn speed(ship: Ship) -> Float {
  ship.speed * global_speed_multiplier
  |> int.to_float()
}

fn travel_time_for_distance(
  distance: Float,
  speed: Float,
) -> duration.Duration {
  float.round(distance /. speed *. 3600.0) |> duration.seconds
}

/// Returns travel time for this ship.
pub fn travel_time(
  from: Waypoint,
  to: Waypoint,
  ship: Ship,
) -> duration.Duration {
  distance(from, to)
  |> travel_time_for_distance(speed(ship))
}

/// Calculates the magnitude of the distance vector between A and B
fn distance(a: Waypoint, b: Waypoint) -> Float {
  let dx = a.pos_x - b.pos_x
  let dy = a.pos_y - b.pos_y
  // errors on negative bases with fractional exponents
  // or on 0 base with negative exponents
  // we are doing neither, by construction
  let assert Ok(dist) = int.square_root(dx * dx + dy * dy)
  dist
}
