import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/string
import gleam/time/timestamp
import logging
import space_game/utils/debug
import storail

// IDS =========================================================================

/// A unique (probably) identifier for something.
/// 
/// The `for` type parameter is to avoid mismatching ids.
/// No connection to Discord IDs.
pub type Id(for) {
  // We store the id as a string because then we don't have to worry about
  // (de)serialising it. The string is used for filenames in storail so it must
  // be filesystem safe.
  Id(String)
}

fn id_decoder() -> decode.Decoder(Id(for)) {
  decode.map(decode.string, Id)
}

fn id_to_json(id: Id(for)) {
  let Id(value) = id
  json.string(value)
}

/// Generate a (probably) unique id.
/// 
/// This generates a random 64 bit value as source for the id.
/// We'll need to generate 10^8 ids just to have a 10^-6 % chance of collision.
pub fn new_id() -> Id(for) {
  crypto.strong_random_bytes(8)
  // The URL-safe encode is also filesystem safe.
  |> bit_array.base64_url_encode(True)
  |> Id
}

// GOODS =======================================================================

pub type Good {
  Good(name: String, base_price: Int)
}

fn good_to_json(good: Good) -> json.Json {
  let Good(name:, base_price:) = good
  json.object([
    #("name", json.string(name)),
    #("base_price", json.int(base_price)),
  ])
}

fn good_decoder() -> decode.Decoder(Good) {
  use name <- decode.field("name", decode.string)
  use base_price <- decode.field("base_price", decode.int)
  decode.success(Good(name:, base_price:))
}

// WAYPOINTS ===================================================================

// TODO: Markets
pub type Waypoint {
  Waypoint(id: Id(Waypoint), name: String, pos_x: Int, pos_y: Int)
}

pub const all_waypoints = [
  Waypoint(Id("nowhere"), "Nowhere Station", pos_x: 0, pos_y: 0),
  Waypoint(Id("cynosure"), "Cynosure", pos_x: 4, pos_y: 2),
  Waypoint(Id("axolotl"), "Axolotl Orbital", pos_x: -1, pos_y: 3),
  Waypoint(Id("altaire_4"), "Altaire IV", pos_x: 6, pos_y: 2),
  Waypoint(Id("aldelet"), "Control Aldelet", pos_x: -2, pos_y: 1),
  Waypoint(Id("gravitas"), "Gravitas Factory", pos_x: 3, pos_y: -3),
  Waypoint(Id("last_stop"), "Last Stop", pos_x: 7, pos_y: -9),
  Waypoint(Id("pats_mistake"), "Pat's Mistake", pos_x: -4, pos_y: -2),
  Waypoint(Id("cdera"), "C.D.E.R.A", pos_x: -1, pos_y: -3),
  Waypoint(Id("modewarikus"), "modewarikus", pos_x: -6, pos_y: 2),
  Waypoint(Id("jumbo_jims"), "Jumbo Jim's Pizza Planet", 5, 3),
]

pub fn get_waypoint(id: Id(Waypoint)) -> Result(Waypoint, Nil) {
  list.find(all_waypoints, fn(wp) { wp.id == id })
}

pub fn get_waypoint_by_name(name: String) -> Result(Waypoint, Nil) {
  list.find(all_waypoints, fn(wp) { wp.name == name })
}

// SHIPS =======================================================================

pub type Cargo {
  Cargo(good: Good, quantity: Int)
}

fn cargo_to_json(cargo: Cargo) -> json.Json {
  let Cargo(good:, quantity:) = cargo
  json.object([
    #("good", good_to_json(good)),
    #("quantity", json.int(quantity)),
  ])
}

fn cargo_decoder() -> decode.Decoder(Cargo) {
  use good <- decode.field("good", good_decoder())
  use quantity <- decode.field("quantity", decode.int)
  decode.success(Cargo(good:, quantity:))
}

pub type Position {
  Docked(at: Id(Waypoint))
  Travelling(
    origin: Id(Waypoint),
    destination: Id(Waypoint),
    departed: timestamp.Timestamp,
  )
}

fn position_to_json(position: Position) -> json.Json {
  case position {
    Docked(at:) ->
      json.object([
        #("type", json.string("docked")),
        #("at", id_to_json(at)),
      ])
    Travelling(origin:, destination:, departed:) ->
      json.object([
        #("type", json.string("travelling")),
        #("origin", id_to_json(origin)),
        #("destination", id_to_json(destination)),
        #(
          "departed",
          timestamp.to_unix_seconds(departed) |> float.truncate |> json.int,
        ),
      ])
  }
}

fn position_decoder() -> decode.Decoder(Position) {
  use variant <- decode.field("type", decode.string)
  case variant {
    "docked" -> {
      use at <- decode.field("at", id_decoder())
      decode.success(Docked(at:))
    }
    "travelling" -> {
      use origin <- decode.field("origin", id_decoder())
      use destination <- decode.field("destination", id_decoder())
      use departed <- decode.field(
        "departed",
        decode.int |> decode.map(timestamp.from_unix_seconds),
      )
      decode.success(Travelling(origin:, destination:, departed:))
    }
    _ -> decode.failure(Docked(at: Id("nil_id")), "Position")
  }
}

pub type Ship {
  Ship(
    name: String,
    cargo_capacity: Int,
    speed: Int,
    cargo: List(Cargo),
    position: Position,
    value: Int,
  )
}

fn ship_to_json(ship: Ship) -> json.Json {
  let Ship(name:, cargo_capacity:, speed:, cargo:, position:, value:) = ship
  json.object([
    #("name", json.string(name)),
    #("cargo_capacity", json.int(cargo_capacity)),
    #("speed", json.int(speed)),
    #("cargo", json.array(cargo, cargo_to_json)),
    #("position", position_to_json(position)),
    #("value", json.int(value)),
  ])
}

fn ship_decoder() -> decode.Decoder(Ship) {
  use name <- decode.field("name", decode.string)
  use cargo_capacity <- decode.field("cargo_capacity", decode.int)
  use speed <- decode.field("speed", decode.int)
  use cargo <- decode.field("cargo", decode.list(cargo_decoder()))
  use position <- decode.field("position", position_decoder())
  use value <- decode.field("value", decode.int)
  decode.success(Ship(name:, cargo_capacity:, speed:, cargo:, position:, value:))
}

// PLAYER ======================================================================

pub type Player {
  Player(
    /// Discord IDs can be represented as 64-bit ints but Discord passes them as
    /// strings and it is simplest to stick with that.
    discord_id: String,
    account_balance: Int,
    ship: Ship,
  )
}

fn player_to_json(player: Player) -> json.Json {
  let Player(discord_id:, account_balance:, ship:) = player
  json.object([
    #("discord_id", json.string(discord_id)),
    #("account_balance", json.int(account_balance)),
    #("ship", ship_to_json(ship)),
  ])
}

fn player_decoder() -> decode.Decoder(Player) {
  use discord_id <- decode.field("discord_id", decode.string)
  use account_balance <- decode.field("account_balance", decode.int)
  use ship <- decode.field("ship", ship_decoder())
  decode.success(Player(discord_id:, account_balance:, ship:))
}

pub fn get_player(
  discord_id: String,
  from: Storage,
) -> Result(Player, storail.StorailError) {
  case
    from.players
    |> storail.key(discord_id)
    |> storail.read()
  {
    Ok(player) -> {
      // Validate invariant
      assert player.discord_id == discord_id
      Ok(player)
    }
    Error(e) -> Error(e)
  }
}

fn set_player(
  player: Player,
  in: Storage,
) -> Result(Nil, storail.StorailError) {
  in.players
  |> storail.key(player.discord_id)
  |> storail.write(player)
}

// STORAGE + WRITER ============================================================

pub opaque type Storage {
  Storage(players: storail.Collection(Player))
}

pub fn new_storage(path: String) -> Storage {
  let config = storail.Config(path)
  Storage(players: storail.Collection(
    name: "players",
    to_json: player_to_json,
    decoder: player_decoder(),
    config:,
  ))
}

pub type Message {
  WritePlayer(Player)
}

pub fn writer(name: process.Name(Message), storage: Storage) {
  actor.new(storage)
  |> actor.named(name)
  |> actor.on_message(on_message)
  |> actor.start()
}

fn on_message(storage: Storage, msg: Message) -> actor.Next(Storage, Message) {
  case msg {
    WritePlayer(player) -> {
      let _ =
        set_player(player, storage)
        |> debug.log_ok(
          logging.Debug,
          "Written data for player " <> player.discord_id,
        )
        |> debug.log_error(
          logging.Error,
          "Unable to write player data for " <> player.discord_id,
          storail_error_to_string,
        )
      actor.continue(storage)
    }
  }
}

pub fn storail_error_to_string(error: storail.StorailError) -> String {
  case error {
    storail.ObjectNotFound(namespace:, id:) ->
      "Storail did not find an object with id "
      <> id
      <> " in namespace "
      <> string.join(namespace, "/")
    storail.CorruptJson(path:, detail:) ->
      "Storail found corrupt JSON at path "
      <> path
      <> ". Decoding failed due to error "
      <> debug.json_decode_error_to_string(detail)
    storail.FileSystemError(path:, detail:) ->
      "Storail encountered a filesystem error at path "
      <> path
      <> ". The filesystem error was "
      <> string.inspect(detail)
  }
}
