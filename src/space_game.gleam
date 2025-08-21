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
import discord/commands.{type SlashCommand, NestedCommand, Subcommand}
import discord/interactions.{type InteractionEvent}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import glenvy/dotenv
import glenvy/env
import goods
import logging
import player
import ship
import sqlight
import waypoints

/// The context holds immutable global state
/// such as precomputed values derived from environment variables.
pub type Context {
  Context(db: String, goods: dict.Dict(String, goods.Goods))
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
  let ctx = Context(db: database_path, goods: goods.goods_dict(goods.all_goods))
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
    NestedCommand(
      cmd: "ship",
      description: "Acquire and control ships",
      install_context: commands.InstallEverywhere,
      interaction_contexts: commands.UseInGuildOrUserDM,
      subcommands: [
        Subcommand(
          cmd: "buy",
          description: "Buy a ship (60,000 credits)",
          required_options: [
            commands.StringOpt(
              name: "name",
              description: "The name of your ship",
            ),
          ],
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
        ["ship", "buy"] -> handle_ship_purchase(ctx, bot, event)
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
        "We were unable to read your identification papers.",
      )
  }
}

// Grab user in deferred events
fn with_user(
  event: interactions.InteractionEvent,
  then fun: fn(interactions.User) -> interactions.ResponseUpdate,
) -> interactions.ResponseUpdate {
  case event.user {
    Some(user) -> fun(user)
    None -> interactions.ResponseUpdate("We cannot identify you.")
  }
}

fn handle_ship_purchase(ctx: Context, bot: Bot, event: InteractionEvent) {
  use <- interactions.defer_response(bot, event, False)
  use user <- with_user(event)
  use conn <- database.with_writable_connection(ctx.db)
  case { waypoints.select_all_waypoints(conn) |> result.map(list.shuffle) } {
    Ok([]) ->
      interactions.ResponseUpdate(
        "There are no waypoints to place your ship at",
      )
    Ok([location, ..]) -> {
      // The assert is safe here because Discord enforces that the option is present.
      // And if things go wrong and we *do* panic then the only impact is that the command
      // fails.
      //
      // TODO: This option interface kinda sucks, see if we can rewrite options
      // so we don't have to pattern match on type.
      // Partition the dict into typed dicts?
      // Yeah, then we can ditch the Option value wrapper.
      let assert Ok(interactions.ValueStr(name)) =
        event.options |> dict.get("name")
      let new_ship =
        ship.NewDockedShip(
          name:,
          owner_id: user.id,
          cargo_capacity: 100,
          speed: 10.0,
          location:,
        )
      let purchase = {
        use _ <- player.with_cost(conn, user.id, 60_000)
        ship.insert_ships(conn, [new_ship])
      }
      case purchase {
        Ok(_) -> {
          logging.log(logging.Debug, "Sold ship to " <> user.id)
          interactions.ResponseUpdate("Congratulations on your purchase.")
        }
        Error(player.InsufficentFunds(bal)) -> {
          interactions.ResponseUpdate(
            "You cannot afford this right now. Your current balance is "
            <> int.to_string(bal)
            <> " credits.",
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to insert ship:\n" <> string.inspect(e),
          )
          interactions.ResponseUpdate("Unable to register your ship")
        }
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "Unable to fetch waypoints list:\n" <> string.inspect(e),
      )
      interactions.ResponseUpdate(
        "We've lost our maps so we are unable to deliver your ship.",
      )
    }
  }
}

fn define_tables(conn: sqlight.Connection) {
  use _ <- result.try(waypoints.create_waypoints_table(conn))
  use _ <- result.try(player.create_players_table(conn))
  ship.create_ships_table(conn)
}
