//// Main entrypoint for space game
//// 
//// # Environment Variables
//// ## SPACE_GAME_DATABASE PATH
//// Path to sqlite database.
//// *Default: "space-game.sqlite3"* 

import database/database
import envoy
import gleam/result
import gleam/string
import logging

/// The context holds immutable global state
/// such as precomputed values derived from environment variables.
pub type Context {
  Context(db: String)
}

pub fn main() -> Nil {
  let database_path =
    envoy.get("SPACE_GAME_DATABASE_PATH") |> result.unwrap("space-game.sqlite3")
  let ctx = Context(database_path)

  case database.init_database(ctx.db) {
    Ok(Nil) -> logging.log(logging.Debug, "Database initialised")
    Error(e) ->
      panic as { "Unable to initalise database: " <> string.inspect(e) }
  }

  // Pass context to all other methods, like the bot, so 
  // they have access to database path and the like.

  Nil
}
