//// Main entrypoint for space game
//// 
//// # Environment Variables
//// ## SPACE_GAME_DATABASE PATH
//// Path to sqlite database.
//// *Default: "space-game.sqlite3"* 

import database/database
import discord
import discord_gleam
import discord_gleam/discord/intents
import discord_gleam/types/bot.{type Bot}
import discord_gleam/types/slash_command
import discord_gleam/ws/packets/interaction_create.{type InteractionCreatePacket}
import gleam/option.{None, Some}
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
  // `discord_gleam.run` is non-terminating so
  // this needs to be the last thing in the main function
  let discord_token = env.string("SPACE_GAME_DISCORD_TOKEN")
  let discord_client_id = env.string("SPACE_GAME_DISCORD_CLIENT_ID")

  case discord_token, discord_client_id {
    // If both tokens are present create the bot
    Ok(token), Ok(client_id) -> {
      let bot = discord_gleam.bot(token, client_id, intents.default())

      // Embed the context into a closure
      discord.start_bot(bot, fn(bot, data) { handle_command(bot, data, ctx) })

      // Register commands
      let _ = discord_gleam.wipe_global_commands(bot)
      let _ =
        discord_gleam.register_global_commands(bot, [
          slash_command.SlashCommand(
            name: "test",
            description: "Test command",
            options: [
              slash_command.CommandOption(
                name: "opt1",
                description: "Test option",
                type_: slash_command.StringOption,
                required: False,
              ),
            ],
          ),
        ])

      Nil
    }
    // If we're missing one environment variable this is a configuration error
    Ok(_), Error(_) ->
      logging.log(
        logging.Error,
        "Unable to prepare Discord bot: SPACE_GAME_DISCORD_CLIENT_ID not set",
      )
    Error(_), Ok(_) ->
      logging.log(
        logging.Error,
        "Unable to prepare Discord bot: SPACE_GAME_DISCORD_TOKEN not set",
      )
    // If we're missing both the user may not be developing it without running the bot so we only warn
    Error(_), Error(_) ->
      logging.log(
        logging.Warning,
        "Unable to prepare Discord bot: Environment not configured",
      )
  }
}

/// Routes commands to handlers
/// https://hexdocs.pm/discord_gleam/discord_gleam/ws/packets/interaction_create.html#InteractionCreateData
fn handle_command(
  _bot: Bot,
  interaction: InteractionCreatePacket,
  ctx: Context,
) -> Nil {
  case interaction.d.data.name {
    "test" -> example_handler(interaction, ctx)
    name -> logging.log(logging.Warning, "Unrecognised command: " <> name)
  }
}

fn example_handler(interaction: InteractionCreatePacket, _ctx: Context) -> Nil {
  // Suppress warning about unused result by assigning it to a discard pattern
  let _ = case interaction.d.data.options {
    Some([]) | None ->
      discord_gleam.interaction_reply_message(interaction, "Hello world", True)
    Some([first, ..]) ->
      case first {
        interaction_create.InteractionOption(
          name,
          _type_,
          interaction_create.StringValue(value),
          _options,
        ) ->
          discord_gleam.interaction_reply_message(
            interaction,
            "Option " <> name <> " has value " <> value,
            True,
          )
        _ ->
          discord_gleam.interaction_reply_message(
            interaction,
            "Unknown options",
            True,
          )
      }
  }
  Nil
}
