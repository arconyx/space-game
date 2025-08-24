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
import discord/interactions.{
  type InteractionEvent, ResponseUpdate, StandaloneResponse,
}
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
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

  process.spawn(fn() { refresh_forever(ctx, 6 * 60 * 1000) })

  process.sleep_forever()
}

/// Update the status of all ships in flight
fn refresh_forever(ctx: Context, period_ms: Int) {
  // TODO: There has to be a better solution than this loop
  // Refresh after every command, but with a rate limit/cooldown
  // so we don't do it too often?
  let refresh = {
    use conn <- database.with_writable_connection(ctx.db)
    ship.refresh_all_ships(conn)
  }
  case refresh {
    Ok(_) -> logging.log(logging.Info, "Ships refreshed")
    Error(e) ->
      logging.log(
        logging.Error,
        "Unable to refresh ships:\n" <> string.inspect(e),
      )
  }
  process.sleep(period_ms)
  refresh_forever(ctx, period_ms)
}

fn define_tables(conn: sqlight.Connection) {
  use _ <- result.try(waypoints.create_waypoints_table(conn))
  use _ <- result.try(player.create_players_table(conn))
  ship.create_ships_table(conn)
}

/// This function just splits out the command definitons from the
/// main method for readability
fn define_commands() -> List(SlashCommand) {
  // TODO: Builder methods to reduce boilerplate
  [
    TopLevelCommand(
      cmd: "waypoints",
      description: "List all waypoints",
      install_context: commands.InstallEverywhere,
      interaction_contexts: commands.UseAnywhere,
      required_options: [],
      optional_options: [],
    ),
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
        Subcommand(
          cmd: "travel",
          description: "Fly to a waypoint",
          required_options: [
            commands.StringOpt(
              name: "destination",
              description: "The name of the destination waypoint",
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
        ["ship", "travel"] -> handle_travel_start(ctx, bot, event)
        ["waypoints"] -> handle_list_waypoints(ctx, bot, event)
        [] -> logging.log(logging.Warning, "Empty command string")
        _ -> logging.log(logging.Warning, "Unhandled command")
      }
  }
}

/// Register a new player
fn handle_registration(ctx: Context, bot: Bot, event: InteractionEvent) {
  use <- interactions.with_response(bot, event)
  // The return value of this block is used as the response
  case event.user {
    Some(interactions.User(id, name)) -> {
      use conn <- database.with_writable_connection(ctx.db)
      case player.select_player(conn, id) {
        Ok(Some(_)) ->
          StandaloneResponse("You are already a registered trader.", True)
        Ok(None) ->
          case player.insert_players(conn, [player.Player(id, 100_000)]) {
            Ok(_) ->
              StandaloneResponse(
                "Welcome to the Trader's Guild " <> name <> "!",
                False,
              )
            Error(e) -> {
              logging.log(
                logging.Error,
                "Unable to register new player:\n" <> string.inspect(e),
              )
              StandaloneResponse(
                "We apologise "
                  <> name
                  <> ", but our registration software is broken right now.",
                True,
              )
            }
          }
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to read player list:\n" <> string.inspect(e),
          )
          StandaloneResponse(
            "Sorry "
              <> name
              <> ", but we can't check the registered traders list right now.",
            True,
          )
        }
      }
    }
    None ->
      StandaloneResponse(
        "Error: We were unable to read your identification papers.",
        True,
      )
  }
}

/// Print the user's account balance
fn handle_balance_check(ctx: Context, bot: Bot, event: InteractionEvent) {
  // Return a "bot is thinking" message
  // The boolean arg is for ephemeral messages (i.e. only visible to the caller)
  use <- interactions.with_response(bot, event)
  // When this block returns the response is updated
  // with the return value
  case event.user {
    Some(interactions.User(id, name)) -> {
      use conn <- database.with_readonly_connection(ctx.db)
      case player.select_player(conn, id) {
        Ok(Some(player)) ->
          StandaloneResponse(
            "You have "
              <> int.to_string(player.money)
              <> " credits in your account.",
            True,
          )
        Ok(None) ->
          StandaloneResponse(
            "You are not registered with this institution.",
            True,
          )
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to read player list:\n" <> string.inspect(e),
          )
          StandaloneResponse(
            "Sorry "
              <> name
              <> ", but we can't check the registered traders list right now.",
            True,
          )
        }
      }
    }
    None ->
      StandaloneResponse(
        "We were unable to read your identification papers.",
        True,
      )
  }
}

// Grab user in events
fn with_user(
  event: interactions.InteractionEvent,
  error: a,
  then fun: fn(interactions.User) -> a,
) -> a {
  case event.user {
    Some(user) -> fun(user)
    None -> error
  }
}

fn handle_ship_purchase(ctx: Context, bot: Bot, event: InteractionEvent) {
  // Deferring the response displays a "bot is thinking" message
  // giving us 15 minutes to response instead of a few seconds.
  use <- interactions.defer_response(bot, event, False)
  use user <- with_user(event, ResponseUpdate("We couldn't identify you."))
  use conn <- database.with_writable_connection(ctx.db)
  case { waypoints.select_all_waypoints(conn) |> result.map(list.shuffle) } {
    Ok([]) -> ResponseUpdate("There are no waypoints to place your ship at")
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

      // We run the transaction using the `with_cost` transaction helper
      case
        player.with_cost(conn, user.id, 60_000, fn(_player) {
          ship.insert_ships(conn, [new_ship])
        })
      {
        Ok(_) -> {
          logging.log(logging.Debug, "Sold ship to " <> user.id)
          ResponseUpdate("Congratulations on your purchase.")
        }
        Error(player.InsufficentFunds(bal)) ->
          ResponseUpdate(
            "You cannot afford this right now. Your current balance is "
            <> int.to_string(bal)
            <> " credits.",
          )
        Error(player.PlayerNotFound) ->
          ResponseUpdate("You are not a registered trader.")
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to insert ship:\n" <> string.inspect(e),
          )
          ResponseUpdate("Unable to register your ship")
        }
      }
    }
    Error(e) -> {
      logging.log(
        logging.Error,
        "Unable to fetch waypoints list:\n" <> string.inspect(e),
      )
      ResponseUpdate(
        "We've lost our maps so we are unable to deliver your ship.",
      )
    }
  }
}

/// Convert a duration to a human readable string
fn duration_to_string(dur: duration.Duration) -> String {
  case duration.to_seconds(dur) {
    seconds if seconds <. 60.0 ->
      float.truncate(seconds) |> int.to_string <> " seconds"
    seconds if seconds <. 3600.0 ->
      float.truncate(seconds /. 60.0) |> int.to_string <> " minutes"
    seconds -> {
      let seconds_string = float.to_string(seconds /. 3600.0)
      // ugly way to limit the number of decimal places
      // TODO: Look into float.to_precision
      case string.split_once(seconds_string, ",") {
        Ok(#(integral, decimal)) ->
          integral
          <> string.drop_end(decimal, int.max(0, 2 - string.length(decimal)))
          <> " hours"
        Error(_) -> seconds_string <> " hours"
      }
    }
  }
}

/// Convert a waypoint to a human readable string with travel time information
fn waypoint_to_string(waypoint: waypoints.Waypoint, ship: ship.Ship) -> String {
  case ship {
    ship.DockedShip(location:, ..) ->
      case location == waypoint {
        True -> waypoint.name <> " (you are here)"
        False ->
          waypoint.name
          <> " ("
          <> duration_to_string(ship.waypoint_travel_time(ship, waypoint))
          <> " away)"
      }
    ship.TravellingShip(departed_from:, destination:, ..) ->
      case waypoint {
        w if w == destination -> waypoint.name <> " (destination)"
        w if w == departed_from ->
          waypoint.name
          <> " (departed, "
          <> duration_to_string(ship.waypoint_travel_time(ship, w))
          <> " away from "
          <> destination.name
          <> ")"
        w ->
          waypoint.name
          <> " ("
          <> duration_to_string(ship.waypoint_travel_time(ship, w))
          <> ")"
      }
  }
}

/// Print a list of waypoints with travel time information
fn handle_list_waypoints(ctx: Context, bot: Bot, event: InteractionEvent) {
  use <- interactions.defer_response(bot, event, True)
  use conn <- database.with_readonly_connection(ctx.db)
  // Get a player's ships, if they have any.
  // This command works even for unregistered players and players without ships
  // so we do special handling for the absence of ships.
  let ships =
    option.map(event.user, fn(u) { ship.select_ships_for_player(conn, u.id) })
  // Grab all the waypoints from the database.
  case waypoints.select_all_waypoints(conn), ships {
    // This is the case where the player has ships
    // We just use the first ship returned for now.
    // TODO: Some way to select ship.
    Ok(all_waypoints), Some(Ok([first_ship, ..])) -> {
      let waypoint_strings =
        all_waypoints
        |> list.map(waypoint_to_string(_, first_ship))
        |> string.join("\n")

      interactions.ResponseUpdate("### Waypoints:\n" <> waypoint_strings)
    }
    // Deal with some edgecases that have similar handling
    Ok(all_waypoints), ship_list -> {
      case ship_list {
        Some(Ok([])) -> Nil
        // This is impossible because of the previous check but the compiler doesn't know that
        Some(Ok(ships)) ->
          logging.log(
            logging.Error,
            "Got ships but this should have been caught by the outer case:\n"
              <> string.inspect(ships),
          )
        Some(Error(e)) ->
          logging.log(
            logging.Error,
            "Unable to fetch ships for player:\n" <> string.inspect(e),
          )
        None -> Nil
      }
      let waypoint_strings =
        all_waypoints |> list.map(fn(w) { w.name }) |> string.join("\n")
      interactions.ResponseUpdate("### Waypoints:\n" <> waypoint_strings)
    }
    // Thematic error messages for when the database read fails
    Error(e), _ -> {
      logging.log(
        logging.Error,
        "Unable to fetch waypoint list:\n" <> string.inspect(e),
      )
      interactions.ResponseUpdate(
        "Navigational systems have suffered a critical failure",
      )
    }
  }
}

/// Tell a ship to fly to a waypoint.
pub fn handle_travel_start(ctx: Context, bot: Bot, event: InteractionEvent) {
  use <- interactions.defer_response(bot, event, True)
  use user <- with_user(event, ResponseUpdate("We couldn't identify you."))
  use conn <- database.with_writable_connection(ctx.db)
  // TODO: Better option handling
  let assert Ok(interactions.ValueStr(name)) =
    event.options |> dict.get("destination")
  // Find the waypoint and the ship
  // Right now we default to the first ship
  // TODO: Ship selection
  case
    waypoints.select_waypoint_by_name(conn, name),
    ship.select_ships_for_player(conn, user.id)
  {
    // Waypoint found in database, player has ship(s)
    Ok(Some(waypoint)), Ok([ship, ..]) -> {
      let time = ship.waypoint_travel_time(ship, waypoint)
      echo time
      // Write travel information to database
      case ship.travel_to_waypoint(conn, ship, waypoint) {
        Ok(_) -> {
          // Start a background process responsible for updating flight status
          // on arrival
          process.spawn_unlinked(fn() {
            duration.to_seconds(time) *. 1000.0 +. 100.0
            |> float.ceiling
            |> float.truncate
            |> process.sleep
            use conn <- database.with_writable_connection(ctx.db)
            case ship.refresh_all_ships(conn) {
              Ok(_) -> logging.log(logging.Info, "Ships refreshed")
              Error(e) ->
                logging.log(
                  logging.Error,
                  "Unable to refresh ships:\n" <> string.inspect(e),
                )
            }
          })
          // Inform the user
          let arrival =
            timestamp.system_time()
            |> timestamp.add(time)
            |> timestamp.to_unix_seconds
            |> float.truncate
            |> int.to_string
          interactions.ResponseUpdate(
            "Departing for " <> name <> ". Arriving <t:" <> arrival <> ":R>.",
          )
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to start travel:\n" <> string.inspect(e),
          )
          interactions.ResponseUpdate(
            "Engine malfunction! You are stuck in dock.",
          )
        }
      }
    }
    Ok(None), _ ->
      interactions.ResponseUpdate("Unable to find a waypoint called " <> name)
    _, Ok([]) -> interactions.ResponseUpdate("You don't have any ships")
    Error(e), _ -> {
      logging.log(
        logging.Error,
        "Unable to fetch waypoint:\n" <> string.inspect(e),
      )
      interactions.ResponseUpdate(
        "Unable to locate that waypoint due to an error.",
      )
    }
    _, Error(e) -> {
      logging.log(
        logging.Error,
        "Unable to fetch ships for player:\n" <> string.inspect(e),
      )
      interactions.ResponseUpdate("Unable to fetch your ships.")
    }
  }
}
