import cake/adapter/sqlite
import cake/insert
import cake/select
import cake/update
import cake/where
import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import logging
import space_game/database
import sqlight.{type Connection}

pub const table = "players"

/// A player, as represented in the database.
///
/// The id matches the Discord user id. This is a 64 bit
/// int but Discord presents it as string so we copy them
/// and avoid having to parse it.
pub type Player {
  Player(discord_id: String, money: Int)
}

/// Table has an String primary key associated with the Discord user id and an integer `money` field.
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
  players: List(Player),
) -> Result(List(Player), sqlight.Error) {
  players
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

// TODO: Transaction history?

pub fn set_funds(
  conn: Connection,
  player_id: String,
  new_balance: Int,
) -> Result(Player, PurchaseError(_)) {
  update.new()
  |> update.table(table)
  |> update.set(update.set_int("money", new_balance))
  |> update.where(where.col("discord_id") |> where.eq(where.string(player_id)))
  |> update.returning(["discord_id", "money"])
  |> update.to_query
  |> sqlite.run_write_query(sql_to_player(), conn)
  |> result.map_error(SQL)
  |> result.try(fn(players) {
    logging.log(
      logging.Debug,
      "Set funds for " <> player_id <> " to " <> int.to_string(new_balance),
    )
    case players {
      [player] -> {
        echo player.money
        player |> Ok
      }
      [] -> PlayerNotFound |> Error
      [player, _, ..] -> {
        logging.log(
          logging.Warning,
          "Got multiple players with the same ID, which should be impossible",
        )
        player |> Ok
      }
    }
  })
}

pub type PurchaseError(e) {
  InsufficentFunds(Int)
  PlayerNotFound
  SQL(sqlight.Error)
  Generic(e)
}

/// Perform a database operation, subtracting funds from the player's account
/// and gracefully rolling back errors.
///
/// Expects a writeable connection.
pub fn with_cost(
  conn: Connection,
  player_id: String,
  cost: Int,
  transaction inner: fn(Player) -> Result(a, e),
) -> Result(a, PurchaseError(e)) {
  logging.log(
    logging.Debug,
    "Performing financial transaction for "
      <> player_id
      <> " with cost "
      <> int.to_string(cost),
  )
  // get player and check they have enough money
  case select_player(conn, player_id) {
    Ok(Some(Player(money:, ..))) if money < cost ->
      InsufficentFunds(money) |> Error
    // this is the case where they can afford the purchase
    Ok(Some(Player(money:, ..))) -> {
      {
        use <- database.as_transaction(conn)
        set_funds(conn, player_id, money - cost)
        |> result.try(fn(updated_player) {
          inner(updated_player) |> result.map_error(Generic)
        })
      }
      |> result.map_error(SQL)
      |> result.flatten
    }
    Ok(None) -> PlayerNotFound |> Error
    Error(e) -> SQL(e) |> Error
  }
}
