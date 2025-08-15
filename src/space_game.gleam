//// Main entrypoint for space game
//// 
//// # Environment Variables
//// ## SPACE_GAME_DATABASE PATH
//// Path to sqlite database.
//// *Default: "space-game.sqlite3"* 

import database/database
import discord_gleam
import discord_gleam/discord/intents
import discord_gleam/types/bot.{type Bot}
import gleam/result
import gleam/string
import glenvy/dotenv
import glenvy/env
import logging

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

  // I believe `discord_gleam.run` is non-terminating so
  // this needs to be the last thing in the main function
  case prepare_discord_bot() {
    // event handlers get passed in this list but we haven't defined any yet
    Ok(bot) -> discord_gleam.run(bot, [])
    Error(Nil) -> logging.log(logging.Warning, "Unable to start bot")
  }

  // Test if we can run code pass the prepare_discord_bot case
  echo "Wow I didn't think we'd get here. Unless there was an error, that would make sense"

  Nil
}

fn prepare_discord_bot() -> Result(Bot, Nil) {
  let discord_token = env.string("SPACE_GAME_DISCORD_TOKEN")
  let discord_client_id = env.string("SPACE_GAME_DISCORD_CLIENT_ID")

  case discord_token, discord_client_id {
    // If both tokens are present create the bot
    Ok(token), Ok(client_id) ->
      discord_gleam.bot(token, client_id, intents.default()) |> Ok
    // If we're missing one environment variable this is a configuration error
    Ok(_), Error(_) ->
      logging.log(
        logging.Error,
        "Unable to prepare Discord bot: SPACE_GAME_DISCORD_CLIENT_ID not set",
      )
      |> Error
    Error(_), Ok(_) ->
      logging.log(
        logging.Error,
        "Unable to prepare Discord bot: SPACE_GAME_DISCORD_TOKEN not set",
      )
      |> Error
    // If we're missing both the user may not be developing it without running the bot so we only warn
    Error(_), Error(_) ->
      logging.log(
        logging.Warning,
        "Unable to prepare Discord bot: Environment not configured",
      )
      |> Error
  }
}
