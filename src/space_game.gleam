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
import discord/commands.{
  type SlashCommand, NestedCommand, Subcommand, TopLevelCommand,
}
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

  let assert Ok(bot) =
    // normally we'd pass glboal commands in the second arg but for
    // testing we're using guild args because they update faster
    bot.start_bot(discord_token, [], command_handler)

  // Test code
  let assert Ok(guild) = env.string("SPACE_GAME_TEST_GUILD_ID")
  let assert Ok(_) =
    commands.register_guild_commands(bot, guild, define_commands())

  process.sleep_forever()
}

/// This function just splits out the command definitons from the
/// main method for readability
fn define_commands() -> List(SlashCommand) {
  // TODO: Builder methods to reduce boilerplate
  [
    TopLevelCommand(
      cmd: "test",
      description: "Test command",
      install_context: commands.InstallEverywhere,
      interaction_contexts: commands.UseAnywhere,
      required_options: [],
      optional_options: [],
    ),
    NestedCommand(
      cmd: "subtest",
      description: "This has subcommands",
      install_context: commands.InstallEverywhere,
      interaction_contexts: commands.UseInGuildOrUserDM,
      subcommands: [
        Subcommand(
          cmd: "ephemeral",
          description: "This makes an ephemeral message",
          required_options: [],
          optional_options: [],
        ),
        Subcommand(
          cmd: "public",
          description: "This makes an public message",
          required_options: [],
          optional_options: [],
        ),
      ],
    ),
  ]
}

/// Route commands to handler functions
fn command_handler(bot: Bot, event: InteractionEvent) {
  case event {
    // Handle /commands
    // This is future proofing against supporting more command types
    interactions.ChatInput(command:, ..) ->
      // Select a handler by matching on the command
      //  which is a list `["root", "sub1", "sub2", ...]`
      case command {
        ["test"] -> handle_test(bot, event)
        ["subtest", "ephemeral"] -> handle_subtest_ephemeral(bot, event)
        ["subtest", "public"] -> handle_subtest_public(bot, event)

        [] -> logging.log(logging.Warning, "Empty command string")
        _ -> logging.log(logging.Warning, "Unhandled command")
      }
  }
}

/// Handle the command "/test"
fn handle_test(bot: Bot, event: InteractionEvent) {
  // Return a "bot is thinking" message
  // The boolean arg is for ephemeral messages (i.e. only visible to the caller)
  use <- interactions.defer_response(bot, event, False)
  // When this block returns the response is updated
  // with the return value
  interactions.ResponseUpdate("Hello world")
}

/// Handle the command "/subtest ephemeral"
fn handle_subtest_ephemeral(bot: Bot, event: InteractionEvent) {
  // Setting ephemeral to true
  use <- interactions.defer_response(bot, event, True)
  interactions.ResponseUpdate("This is an ephemeral message")
}

/// Handle the command "/subtest public"
fn handle_subtest_public(bot: Bot, event: InteractionEvent) {
  use <- interactions.defer_response(bot, event, False)
  interactions.ResponseUpdate("This is a normal message")
}
