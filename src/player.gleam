import cake/adapter/sqlite
import cake/insert
import cake/select
import cake/where
import database
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import logging
import sqlight.{type Connection}

const table = "players"

/// A player, as represented in the database.
///
/// The id matches the Discord user id. This is a 64 bit
/// int but Discord presents it as string so we copy them
/// and avoid having to parse it.
pub type Player {
  Player(discord_id: String, money: Int)
}

/// Table has an integer primary key and a unique name.
/// The (x,y) pair must also be unique as no two waypoints
/// can share the same position.
pub fn create_players_table(conn: Connection) -> Result(Nil, sqlight.Error) {
  database.create_table(
    conn,
    table,
    database.PrimaryKeyColumn(
      name: "discord_id",
      datatype: database.Text,
      constraints: "CHECK(discord_id != '')",
    ),
    [
      database.simple_col("money", database.Integer),
    ],
    "",
  )
}

fn player_to_sql(player: Player) -> insert.InsertRow {
  [player.discord_id |> insert.string, player.money |> insert.int]
  |> insert.row
}

/// expects [discord_id, money]
fn sql_to_player() -> decode.Decoder(Player) {
  use discord_id <- decode.field(0, decode.string)
  use money <- decode.field(1, decode.int)
  Player(discord_id:, money:) |> decode.success
}

/// Register a new player.
/// This will fail if the player is already registered.
pub fn insert_players(
  conn: Connection,
  waypoints: List(Player),
) -> Result(List(Player), sqlight.Error) {
  waypoints
  |> insert.from_records(table, ["discord_id", "money"], _, player_to_sql)
  |> insert.returning(["discord_id", "money"])
  |> insert.to_query
  |> sqlite.run_write_query(sql_to_player(), conn)
}

/// Return a list of all players.
pub fn select_all_players(
  conn: Connection,
) -> Result(List(Player), sqlight.Error) {
  select.new()
  |> select.from_table(table)
  |> select.select_cols(["discord_id", "money"])
  |> select.to_query()
  |> sqlite.run_read_query(sql_to_player(), conn)
}

/// Select a single player by (Discord) ID.
/// This returns an option to account for unregistered players.
pub fn select_player(
  conn: Connection,
  discord_id: String,
) -> Result(Option(Player), sqlight.Error) {
  select.new()
  |> select.from_table(table)
  |> select.select_cols(["discord_id", "money"])
  |> select.where(where.col("discord_id") |> where.eq(where.string(discord_id)))
  |> select.to_query()
  |> sqlite.run_read_query(sql_to_player(), conn)
  |> result.map(fn(players) {
    case players {
      [player] -> Some(player)
      [] -> None
      [player, _, ..] -> {
        logging.log(
          logging.Warning,
          "Got multiple players with the same ID, which should be impossible",
        )
        Some(player)
      }
    }
  })
}
