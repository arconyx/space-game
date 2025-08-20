//// Main entrypoint for space game
//// 
//// # Environment Variables
//// 
//// ## SPACE_GAME_DATABASE PATH
//// Path to sqlite database.
//// *Default: "space-game.sqlite3"* 
//// 
//// ## SPACE_GAME_DISCORD_TOKEN
//// Discord bot authorisation token
////
//// ## SPACE_GAME_TEST_GUILD_ID
//// Server ID used to register guild commands in test code.
//// Enable dev mode in Discord's advanced settings, then right click
//// on the server icon to obtain it.

import database
import discord/bot.{type Bot}
import discord/commands.{
  type SlashCommand, NestedCommand, Subcommand, TopLevelCommand,
}
import discord/interactions.{type InteractionEvent}
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glenvy/dotenv
import glenvy/env
import logging
import player
import sqlight
import waypoints

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

  case database.init_database(ctx.db, define_tables) {
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
    bot.start_bot(discord_token, [], fn(bot, event) {
      // embedding the context with a closure
      command_handler(ctx, bot, event)
    })

  // Test code
  let assert Ok(guild) = env.string("SPACE_GAME_TEST_GUILD_ID")
  let assert Ok(_) =
    commands.register_guild_commands(bot, guild, define_commands())
  let _ = waypoints.demo_waypoint(ctx.db)

  process.sleep_forever()
}

/// This function just splits out the command definitons from the
/// main method for readability
fn define_commands() -> List(SlashCommand) {
  // TODO: Builder methods to reduce boilerplate
  [
    // Replaced by a new version but retained as a demo of top level commands
    // TopLevelCommand(
    //   cmd: "register",
    //   description: "Register as a new player",
    //   install_context: commands.InstallEverywhere,
    //   interaction_contexts: commands.UseAnywhere,
    //   required_options: [],
    //   optional_options: [],
    // ),
    NestedCommand(
      cmd: "account",
      description: "Information on your Trader's Guild account",
      install_context: commands.InstallEverywhere,
      interaction_contexts: commands.UseInGuildOrUserDM,
      subcommands: [
        Subcommand(
          cmd: "register",
          description: "Become a guild registered trader",
          required_options: [],
          optional_options: [],
        ),
        Subcommand(
          cmd: "balance",
          description: "Get your current account balance",
          required_options: [],
          optional_options: [],
        ),
      ],
    ),
  ]
}

/// Route commands to handler functions
fn command_handler(ctx: Context, bot: Bot, event: InteractionEvent) {
  case event {
    // Handle /commands
    // This is future proofing against supporting more command types
    interactions.ChatInput(command:, ..) ->
      // Select a handler by matching on the command
      //  which is a list `["root", "sub1", "sub2", ...]`
      case command {
        ["account", "register"] -> handle_registration(ctx, bot, event)
        ["account", "balance"] -> handle_balance_check(ctx, bot, event)

        [] -> logging.log(logging.Warning, "Empty command string")
        _ -> logging.log(logging.Warning, "Unhandled command")
      }
  }
}

/// Register a new player
fn handle_registration(ctx: Context, bot: Bot, event: InteractionEvent) {
  // Return a "bot is thinking" message
  // The boolean arg is for ephemeral messages (i.e. only visible to the caller)
  use <- interactions.defer_response(bot, event, False)
  // When this block returns the response is updated
  // with the return value
  case event.user {
    Some(interactions.User(id, name)) -> {
      use conn <- database.with_writable_connection(ctx.db)
      case player.select_player(conn, id) {
        Ok(Some(_)) ->
          interactions.ResponseUpdate("You are already a registered trader.")
        Ok(None) ->
          case player.insert_players(conn, [player.Player(id, 100_000)]) {
            Ok(_) ->
              interactions.ResponseUpdate(
                "Welcome to the Trader's Guild " <> name <> "!",
              )
            Error(e) -> {
              logging.log(
                logging.Error,
                "Unable to register new player:\n" <> string.inspect(e),
              )
              interactions.ResponseUpdate(
                "We apologise "
                <> name
                <> ", but our registration software is broken right now.",
              )
            }
          }
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to read player list:\n" <> string.inspect(e),
          )
          interactions.ResponseUpdate(
            "Sorry "
            <> name
            <> ", but we can't check the registered traders list right now.",
          )
        }
      }
    }
    None ->
      interactions.ResponseUpdate(
        "Error: We were unable to read your identification papers.",
      )
  }
}

/// Print the user's account balance
fn handle_balance_check(ctx: Context, bot: Bot, event: InteractionEvent) {
  // Return a "bot is thinking" message
  // The boolean arg is for ephemeral messages (i.e. only visible to the caller)
  use <- interactions.defer_response(bot, event, False)
  // When this block returns the response is updated
  // with the return value
  case event.user {
    Some(interactions.User(id, name)) -> {
      use conn <- database.with_readonly_connection(ctx.db)
      case player.select_player(conn, id) {
        Ok(Some(player)) ->
          interactions.ResponseUpdate(
            "You have "
            <> int.to_string(player.money)
            <> " credits in your account.",
          )
        Ok(None) ->
          interactions.ResponseUpdate(
            "You are not registered with this institution.",
          )
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to read player list:\n" <> string.inspect(e),
          )
          interactions.ResponseUpdate(
            "Sorry "
            <> name
            <> ", but we can't check the registered traders list right now.",
          )
        }
      }
    }
    None ->
      interactions.ResponseUpdate(
        "Error: We were unable to read your identification papers.",
      )
  }
}

fn define_tables(conn: sqlight.Connection) {
  use _ <- result.try(waypoints.create_waypoints_table(conn))
  player.create_players_table(conn)
}
