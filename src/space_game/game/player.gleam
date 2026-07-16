import cake/adapter/sqlite
import cake/fragment
import cake/insert
import cake/select
import cake/update
import cake/where
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import logging
import space_game/database/setup
import space_game/database/write
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
  setup.create_table(
    conn,
    table,
    setup.string_primary_key("discord_id"),
    [
      setup.simple_col("money", setup.Integer),
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

/// Adds `|credit|` to account
pub fn add_funds(conn: Connection, player_id: String, credit: Int) {
  update_funds(conn, player_id, int.absolute_value(credit))
}

/// Removes `|debit|` from account
pub fn remove_funds(conn: Connection, player_id: String, debit: Int) {
  update_funds(conn, player_id, debit |> int.absolute_value() |> int.negate())
}

/// Adds `delta` funds to account. 
/// 
/// If negative, funds will be removed. Prefer `add_funds` and `remove_funds`
/// where possible to avoid issues with negative inputs.
/// TODO: Transaction history?
fn update_funds(
  conn: Connection,
  player_id: String,
  delta: Int,
) -> Result(Player, AccountError) {
  update.new()
  |> update.table(table)
  |> update.set(update.set_fragment(
    "money",
    fragment.prepared("money + ?", [fragment.int(delta)]),
  ))
  |> update.where(where.col("discord_id") |> where.eq(where.string(player_id)))
  |> update.returning(["discord_id", "money"])
  |> update.to_query
  |> sqlite.run_write_query(sql_to_player(), conn)
  |> result.map_error(SQL)
  |> result.try(fn(players) {
    logging.log(
      logging.Debug,
      "Added " <> int.to_string(delta) <> " credits to user " <> player_id,
    )
    case players {
      [player] -> {
        echo player.money
        player |> Ok
      }
      [] -> player_id |> AccountNotFound |> Error
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

pub type AccountError {
  InsufficentFunds(Int)
  AccountNotFound(id: String)
  SQL(sqlight.Error)
}

/// Perform a database operation, subtracting funds from the player's account
/// and gracefully rolling back errors.
/// 
/// The transaction is rolled back if it leaves the player with negative funds
/// or the inner `transaction` function returns an error. The `on_account_error`
/// function is only called for the former case.
/// 
/// The supplied transaction is passed the player *after* the funds have been
/// removed. It is run in the writer process.
pub fn with_cost(
  writer: process.Subject(write.Message),
  player_id: String,
  cost: Int,
  on_account_error on_error: fn(AccountError) -> Nil,
  transaction transaction: fn(Connection, Player) -> Result(Nil, String),
) -> Nil {
  use conn <- write.call_writer(writer)
  logging.log(
    logging.Debug,
    "Performing financial transaction for "
      <> player_id
      <> " with cost "
      <> int.to_string(cost),
  )

  remove_funds(conn, player_id, cost)
  |> result.try(fn(player) {
    case player.money {
      balance if balance < 0 -> InsufficentFunds(balance) |> Error
      _ -> Ok(player)
    }
  })
  |> result.map_error(fn(error) {
    on_error(error)
    "Unable to deduct funds"
  })
  |> result.try(transaction(conn, _))
}
