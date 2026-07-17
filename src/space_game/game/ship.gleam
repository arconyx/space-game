import cake/adapter/sqlite
import cake/combined
import cake/delete
import cake/insert
import cake/join
import cake/select
import cake/update
import cake/where
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import logging
import space_game/database/connection
import space_game/database/setup
import space_game/game/player
import space_game/game/waypoints.{type Waypoint}
import sqlight.{type Connection}

pub const table: String = "ships"

// intended for debugging use by increasing travel times
const global_speed_multiplier: Float = 1.0

pub type Ship {
  DockedShip(
    id: Int,
    name: String,
    owner_id: String,
    cargo_capacity: Int,
    speed: Float,
    location: Waypoint,
  )
  TravellingShip(
    id: Int,
    name: String,
    owner_id: String,
    cargo_capacity: Int,
    speed: Float,
    departed_from: Waypoint,
    destination: Waypoint,
    departed_at: Timestamp,
  )
}

pub fn create_ships_table(conn: Connection) -> Result(Nil, sqlight.Error) {
  setup.create_table(
    conn,
    table,
    setup.integer_primary_key,
    [
      setup.Column(
        name: "name",
        datatype: setup.Text,
        nullable: False,
        constraints: "UNIQUE CHECK(name != '')",
      ),
      setup.Column(
        name: "owner_id",
        datatype: setup.Text,
        nullable: False,
        constraints: "CHECK(owner_id != '')",
      ),
      setup.simple_col("cargo_capacity", setup.Integer),
      setup.Column(
        name: "speed",
        datatype: setup.Real,
        nullable: False,
        constraints: "CHECK(speed > 0)",
      ),
      setup.simple_col("location_id", setup.Integer),
      // if the destination is non-null then we must have a departure time
      // if the destination is null then we're docked
      setup.Column(
        name: "destination_id",
        datatype: setup.Integer,
        nullable: True,
        constraints: "",
      ),
      // epoch seconds
      setup.Column(
        name: "departed_at",
        datatype: setup.Integer,
        nullable: True,
        constraints: "",
      ),
    ],
    "FOREIGN KEY(owner_id) REFERENCES " <> player.table <> "(discord_id),
     FOREIGN KEY(location_id) REFERENCES " <> waypoints.table <> "(id),
     FOREIGN KEY(destination_id) REFERENCES " <> waypoints.table <> "(id),
     CHECK((destination_id == null) == (departed_at == null))
    ",
  )
}

pub type NewShip {
  NewDockedShip(
    name: String,
    owner_id: String,
    cargo_capacity: Int,
    speed: Float,
    location: Waypoint,
  )
}

fn ship_to_sql(ship: NewShip) -> insert.InsertRow {
  case ship {
    NewDockedShip(..) -> [
      ship.name |> insert.string,
      ship.owner_id |> insert.string,
      ship.cargo_capacity |> insert.int,
      ship.speed |> insert.float,
      ship.location.id |> insert.int,
      // destination
      insert.null(),
      // departure time
      insert.null(),
    ]
  }
  |> insert.row
}

fn sql_to_ship() -> decode.Decoder(Ship) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  use owner_id <- decode.field(2, decode.string)
  use cargo_capacity <- decode.field(3, decode.int)
  use speed <- decode.field(4, decode.float)

  use location_id <- decode.field(5, decode.int)
  use location_name <- decode.field(8, decode.string)
  use location_x <- decode.field(9, decode.float)
  use location_y <- decode.field(10, decode.float)

  let location =
    waypoints.Waypoint(
      id: location_id,
      name: location_name,
      x: location_x,
      y: location_y,
    )

  use destination_id <- decode.field(6, decode.optional(decode.int))
  case destination_id {
    Some(destination_id) -> {
      use destination_name <- decode.field(11, decode.string)
      use destination_x <- decode.field(12, decode.float)
      use destination_y <- decode.field(13, decode.float)
      use departed_at <- decode.field(
        7,
        decode.int |> decode.map(timestamp.from_unix_seconds),
      )
      let destination =
        waypoints.Waypoint(
          id: destination_id,
          name: destination_name,
          x: destination_x,
          y: destination_y,
        )
      TravellingShip(
        id:,
        name:,
        owner_id:,
        cargo_capacity:,
        speed:,
        departed_from: location,
        destination:,
        departed_at:,
      )
      |> decode.success
    }
    None ->
      DockedShip(id:, name:, owner_id:, cargo_capacity:, speed:, location:)
      |> decode.success
  }
}

pub fn insert_ships(
  conn: Connection,
  ships: List(NewShip),
) -> Result(List(Int), sqlight.Error) {
  ships
  |> insert.from_records(
    table,
    [
      "name",
      "owner_id",
      "cargo_capacity",
      "speed",
      "location_id",
      "destination_id",
      "departed_at",
    ],
    _,
    ship_to_sql,
  )
  |> insert.returning(["id"])
  |> insert.to_query
  |> sqlite.run_write_query(decode.at([0], decode.int), conn)
}

fn prefix_columns(strings: List(String), prefix: String) -> List(String) {
  use s <- list.map(strings)
  prefix <> s
}

fn make_join(left_col: String, alias: String) -> delete.Join {
  join.table(waypoints.table)
  |> join.left(
    where.col(table <> left_col)
      |> where.eq(where.col(alias <> ".id")),
    alias,
  )
}

fn make_select() -> combined.Select {
  select.new()
  |> select.from_table(table)
  |> select.select_cols(
    [
      ".id",
      ".name",
      ".owner_id",
      ".cargo_capacity",
      ".speed",
      ".location_id",
      ".destination_id",
      ".departed_at",
    ]
    |> prefix_columns(table)
    |> list.append([
      "loc.name",
      "loc.x",
      "loc.y",
      "dest.name",
      "dest.x",
      "dest.y",
    ]),
  )
  |> select.join(make_join(".location_id", "loc"))
  |> select.join(make_join(".destination_id", "dest"))
}

pub fn select_all_ships(conn: Connection) -> Result(List(Ship), sqlight.Error) {
  make_select()
  |> select.to_query
  |> sqlite.run_read_query(sql_to_ship(), conn)
}

pub fn select_ships_for_player(
  conn: Connection,
  player_id: String,
) -> Result(List(Ship), sqlight.Error) {
  make_select()
  |> select.where(where.col("owner_id") |> where.eq(where.string(player_id)))
  |> select.to_query
  |> sqlite.run_read_query(sql_to_ship(), conn)
}

fn speed(ship: Ship) -> Float {
  ship.speed *. global_speed_multiplier
}

fn travel_time_for_distance(
  distance: Float,
  speed: Float,
) -> duration.Duration {
  let l = float.round(distance /. speed *. 3600.0) |> duration.seconds
  logging.log(
    logging.Debug,
    "Calculating speed for distance "
      <> float.to_string(distance)
      <> " speed "
      <> float.to_string(speed)
      <> " as "
      <> float.to_string(duration.to_seconds(l))
      <> " seconds",
  )
  l
}

/// Returns travel time for this ship.
/// For ships in flight we assume transit from their current destination.
pub fn waypoint_travel_time(
  ship: Ship,
  destination: Waypoint,
) -> duration.Duration {
  case ship {
    DockedShip(location:, ..) -> waypoints.distance(location, destination)
    TravellingShip(destination: next, ..) ->
      waypoints.distance(next, destination)
  }
  |> travel_time_for_distance(speed(ship))
}

/// Begin flight to waypoint
pub fn travel_to_waypoint(
  conn: Connection,
  ship: Ship,
  destination: Waypoint,
) -> Result(Nil, sqlight.Error) {
  update.new()
  |> update.table(table)
  |> update.sets([
    update.set_int("destination_id", destination.id),
    update.set_int(
      "departed_at",
      timestamp.system_time()
        |> timestamp.to_unix_seconds
        |> float.truncate,
    ),
  ])
  |> update.where(where.col("id") |> where.eq(where.int(ship.id)))
  |> update.to_query
  |> sqlite.run_write_query(sql_to_ship(), conn)
  |> result.replace(Nil)
}

/// Set location to waypoint
pub fn set_location(
  conn: Connection,
  ship: Ship,
  destination: Waypoint,
) -> Result(Nil, sqlight.Error) {
  update.new()
  |> update.table(table)
  |> update.sets([
    update.set_int("location_id", destination.id),
    update.set_null("destination_id"),
    update.set_null("departed_at"),
  ])
  |> update.where(where.col("id") |> where.eq(where.int(ship.id)))
  |> update.to_query
  |> sqlite.run_write_query(sql_to_ship(), conn)
  |> result.replace(Nil)
}

/// Calculate how far through a trip a ship is at a given time as a decimal
/// percentage where >=1 indicates the trip is finished.
pub fn calculate_progress(
  current_time now: Timestamp,
  departed_at start: Timestamp,
  departed_from origin: Waypoint,
  destination destination: Waypoint,
  ship_speed speed: Float,
) -> Float {
  let elapsed = timestamp.difference(start, now)
  let trip_length =
    waypoints.distance(origin, destination)
    |> travel_time_for_distance(speed)
  case duration.to_seconds(trip_length) {
    0.0 -> 1.0
    len -> {
      let elapsed_sec = duration.to_seconds(elapsed)
      let progress = elapsed_sec /. len
      logging.log(
        logging.Debug,
        "Elapsed time: "
          <> float.to_string(elapsed_sec)
          <> "s, trip length: "
          <> float.to_string(len)
          <> "s, progress: "
          <> float.to_string(progress),
      )
      progress
    }
  }
}

/// Update travel status of all ships
fn refresh_all_ships(conn: Connection) -> Result(Nil, sqlight.Error) {
  // TODO: This needs optimising
  // We should be using the db to filter and applying all updates in
  // one go
  let now = timestamp.system_time()
  case select_all_ships(conn) {
    Ok(ships) ->
      list.try_each(ships, fn(ship) {
        case ship {
          TravellingShip(departed_at:, departed_from:, destination:, ..) ->
            case
              calculate_progress(
                current_time: now,
                departed_at:,
                departed_from:,
                destination:,
                ship_speed: speed(ship),
              )
            {
              p if p >=. 1.0 -> set_location(conn, ship, destination)
              _ -> Ok(Nil)
            }
          DockedShip(..) -> Ok(Nil)
        }
      })
    Error(e) -> Error(e)
  }
}

pub type Message {
  RefreshAll
}

pub type State {
  State(
    self: process.Subject(Message),
    db: String,
    period_ms: Int,
    next: option.Option(process.Timer),
  )
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, a) {
  case msg {
    RefreshAll -> {
      // We sometimes trigger refresh from outside the timer loop,
      // so we clear the existing timer to maintain spacing.
      // This is a no-op if the timer has fired.
      option.map(state.next, process.cancel_timer)
      case
        connection.with_writable_connection(state.db, refresh_all_ships)
        |> result.flatten()
      {
        Ok(Nil) -> {
          logging.log(
            logging.Debug,
            "Ships refreshed. Next refresh in "
              <> int.to_string(state.period_ms)
              <> "ms",
          )
          let next =
            process.send_after(state.self, state.period_ms, RefreshAll)
            |> Some
          State(..state, next:)
          |> actor.continue()
        }
        Error(e) -> {
          let delay = state.period_ms / 10
          logging.log(
            logging.Error,
            "Ships refresh error:\n"
              <> string.inspect(e)
              <> "\nNext refresh in "
              <> int.to_string(delay)
              <> "ms",
          )
          let next =
            process.send_after(state.self, delay, RefreshAll)
            |> Some
          State(..state, next:)
          |> actor.continue()
        }
      }
    }
  }
}

pub fn make_ship_worker(
  name: process.Name(Message),
  db: String,
  period_ms: Int,
) -> fn() -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  fn() {
    let subject = process.named_subject(name)
    let worker =
      actor.new(State(self: subject, db:, period_ms:, next: option.None))
      |> actor.named(name)
      |> actor.on_message(handle_message)
      |> actor.start()
    case worker {
      Ok(a) -> process.send(a.data, RefreshAll)
      Error(_) -> Nil
    }
    worker
  }
}
