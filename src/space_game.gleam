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
import discord/bot.{type Bot}
import discord/interactions.{type InteractionEvent}
import gleam/erlang/process
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

  // Configure bot with environment variables
  // Panic if we can't read them
  let assert Ok(discord_token) = env.string("SPACE_GAME_DISCORD_TOKEN")

  let assert Ok(_) = bot.start_bot(discord_token, [], command_handler)
  process.sleep_forever()
}

fn command_handler(bot: Bot, event: InteractionEvent) {
  case event {
    interactions.ChatInput(command:, ..) ->
      case command {
        ["test"] -> handle_test(bot, event)
        [] -> logging.log(logging.Warning, "Empty command string")
        _ -> logging.log(logging.Warning, "Unhandled command")
      }
    // _ -> logging.log(logging.Warning, "Unsupported event type")
  }
}

fn handle_test(bot: Bot, event: InteractionEvent) {
  use <- interactions.defer_response(bot, event, False)
  interactions.ResponseUpdate("Hello world")
}
