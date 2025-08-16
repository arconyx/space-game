//// Main entrypoint for space game
//// 
//// # Environment Variables
//// 
//// ## SPACE_GAME_DATABASE PATH
//// Path to sqlite database.
//// *Default: "space-game.sqlite3"* 
//// 
//// ### SPACE_GAME_DISCORD_TOKEN
//// Discord bot authorisation token

import database/database
import discord/gatehouse
import discord/gateway.{type Interaction}
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import glenvy/dotenv
import glenvy/env
import logging
import stratus.{type Connection}

/// The context holds immutable global state
/// such as precomputed values derived from environment variables.
pub type Context {
  Context(db: String)
}

/// Main entry point
/// This is what `gleam run` calls
pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  // Load environment variables from .env file
  let _ = dotenv.load()

  let database_path =
    env.string("SPACE_GAME_DATABASE_PATH")
    |> result.unwrap("space-game.sqlite3")
  let ctx = Context(database_path)
  // Pass context to all other methods, like the bot, so 
  // they have access to database path and the like.

  case database.init_database(ctx.db) {
    Ok(Nil) -> logging.log(logging.Debug, "Database initialised")
    Error(e) ->
      panic as { "Unable to initalise database: " <> string.inspect(e) }
  }

  // Configure bot with environment variables
  // `discord_gleam.run` is non-terminating so
  // this needs to be the last thing in the main function
  let discord_token = env.string("SPACE_GAME_DISCORD_TOKEN")

  case discord_token {
    // If both tokens are present create the bot
    Ok(token) -> {
      let gh = gatehouse.construct(token, handle_command)

      logging.log(logging.Debug, "Gatehouse constructed")

      case static_supervisor.start(gh) {
        Ok(_) -> logging.log(logging.Info, "Gatehouse started")
        Error(e) ->
          case e {
            actor.InitTimeout ->
              logging.log(logging.Error, "Gatehouse init timed out")
            actor.InitFailed(reason) ->
              logging.log(logging.Error, "Gatehouse init failed: " <> reason)
            actor.InitExited(reason) ->
              logging.log(
                logging.Error,
                "Gatehouse exited during init: " <> string.inspect(reason),
              )
          }
      }
    }
    // If we're missing one environment variable this is a configuration error
    Error(_) ->
      logging.log(
        logging.Warning,
        "Unable to prepare Discord bot: SPACE_GAME_DISCORD_TOKEN not set",
      )
  }

  process.sleep_forever()
}

/// Takes interactions (/commands) and routes them to handler functions
fn handle_command(_interaction: Interaction, _conn: Connection) -> Nil {
  Nil
}
