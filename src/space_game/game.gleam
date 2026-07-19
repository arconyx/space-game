import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import logging
import space_game/database/connection
import space_game/database/write
import space_game/discord/api
import space_game/discord/commands.{
  type SlashCommand, NestedCommand, Subcommand, TopLevelCommand,
}
import space_game/discord/interactions.{
  type InteractionEvent, ResponseUpdate, StandaloneResponse,
}
import space_game/game/goods
import space_game/game/player
import space_game/game/ship
import space_game/game/waypoints
import sqlight

pub type Message {
  Interaction(InteractionEvent)
}

type State {
  State(
    user_id: String,
    bot: api.Bot,
    db: String,
    writer: process.Subject(write.Message),
    ship_refresh_actor: process.Subject(ship.Message),
    goods: dict.Dict(String, goods.Goods),
  )
}

/// TODO: Embed handlers in command objects and automatically generate
/// router from command list
pub fn define_commands() -> List(SlashCommand) {
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

pub fn make_user_actor(
  bot: api.Bot,
  db: String,
  writer: process.Subject(write.Message),
  ship_refresh_actor: process.Subject(ship.Message),
  goods: dict.Dict(String, goods.Goods),
) {
  fn(user_id: String) {
    let a =
      State(user_id:, bot:, db:, writer:, ship_refresh_actor:, goods:)
      |> actor.new()
      |> actor.on_message(command_handler)
      |> actor.start()
    logging.log(logging.Debug, "Started actor for user " <> user_id)
    a
  }
}

/// Route commands to handler functions
fn command_handler(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let Interaction(event) = message
  case event {
    // Handle /commands
    // This is future proofing against supporting more command types
    interactions.ChatInput(command:, ..) ->
      // Select a handler by matching on the command
      //  which is a list `["root", "sub1", "sub2", ...]`
      case command {
        ["account", "register"] -> handle_registration(state, event)
        ["account", "balance"] -> handle_balance_check(state, event)
        ["ship", "buy"] -> handle_ship_purchase(state, event)
        ["ship", "travel"] -> handle_travel_start(state, event)
        ["waypoints"] -> handle_list_waypoints(state, event)
        [] -> logging.log(logging.Warning, "Empty command string")
        _ -> logging.log(logging.Warning, "Unhandled command")
      }
  }
  actor.continue(state)
}

/// If the result is an error log it and return a generic error message
/// as a Standalone Response
fn catch_database_error(
  fun: fn() -> Result(interactions.StandaloneResponse, sqlight.Error),
) -> interactions.StandaloneResponse {
  case fun() {
    Ok(value) -> value
    Error(_) -> {
      logging.log(
        logging.Error,
        "We were unable to open or close a database connection",
      )
      StandaloneResponse("Error: Database connection failed", True)
    }
  }
}

/// If the result is an error log it and return a generic error message
/// as a ResponseUpdate
fn catch_deferred_database_error(
  fun: fn() -> Result(interactions.ResponseUpdate, sqlight.Error),
) -> interactions.ResponseUpdate {
  case fun() {
    Ok(value) -> value
    Error(_) -> {
      logging.log(
        logging.Error,
        "We were unable to open or close a database connection",
      )
      ResponseUpdate("Error: Database connection failed")
    }
  }
}

/// Register a new player
fn handle_registration(state: State, event: InteractionEvent) -> Nil {
  use conn <- write.call_writer(state.writer)
  // TODO: Don't just blindly ok
  Ok(
    interactions.with_response(state.bot, event, fn() {
      let user = event.user
      case player.select_player(conn, user.id) {
        Ok(Some(_)) ->
          StandaloneResponse("You are already a registered trader.", True)
        Ok(None) ->
          case player.insert_players(conn, [player.Player(user.id, 100_000)]) {
            Ok(_) ->
              StandaloneResponse(
                "Welcome to the Trader's Guild " <> user.name <> "!",
                False,
              )
            Error(e) -> {
              logging.log(
                logging.Error,
                "Unable to register new player:\n" <> string.inspect(e),
              )
              StandaloneResponse(
                "We apologise "
                  <> user.name
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
              <> user.name
              <> ", but we can't check the registered traders list right now.",
            True,
          )
        }
      }
    }),
  )
}

/// Print the user's account balance
fn handle_balance_check(state: State, event: InteractionEvent) -> Nil {
  use <- interactions.with_response(state.bot, event)
  let user = event.user
  use <- catch_database_error()
  use conn <- connection.with_readonly_connection(state.db)
  case player.select_player(conn, user.id) {
    Ok(Some(player)) ->
      StandaloneResponse(
        "You have "
          <> int.to_string(player.money)
          <> " credits in your account.",
        True,
      )
    Ok(None) ->
      StandaloneResponse("You are not registered with this institution.", True)
    Error(e) -> {
      logging.log(
        logging.Error,
        "Unable to read player list:\n" <> string.inspect(e),
      )
      StandaloneResponse(
        "Sorry "
          <> user.name
          <> ", but we can't check the registered traders list right now.",
        True,
      )
    }
  }
}

fn handle_ship_purchase(state: State, event: InteractionEvent) -> Nil {
  // Deferring the response displays a "bot is thinking" message
  // giving us 15 minutes to response instead of a few seconds.
  // TODO: Handle deferral error
  let _ = interactions.send_deferral(state.bot, event, False)
  let followup = interactions.edit_response(state.bot, event, _)

  use conn, player <- player.with_cost(
    state.writer,
    event.user.id,
    60_000,
    fn(error) {
      let _ =
        case error {
          player.InsufficentFunds(current_balance) ->
            ResponseUpdate(
              "You cannot afford this right now. Your current balance is "
              <> int.to_string(current_balance)
              <> " credits.",
            )
          player.AccountNotFound(..) ->
            ResponseUpdate("You are not a registered trader.")
          player.SQL(error) -> {
            logging.log(
              logging.Error,
              "Unable to insert ship:\n" <> string.inspect(error),
            )
            ResponseUpdate("Unable to register your ship")
          }
        }
        |> followup()
      Nil
    },
  )

  case waypoints.select_all_waypoints(conn) |> result.map(list.shuffle) {
    Error(e) -> {
      logging.log(
        logging.Error,
        "Unable to fetch waypoints list:\n" <> string.inspect(e),
      )
      let _ =
        ResponseUpdate(
          "We've lost our maps so we are unable to deliver your ship.",
        )
        |> followup()
      Error("Unable to load waypoints")
    }
    Ok([]) -> {
      let _ =
        ResponseUpdate("There are no waypoints to place your ship at")
        |> followup()
      Error("No waypoints")
    }
    Ok([location, ..]) -> {
      // The assert is safe here because Discord enforces that the option is
      // present. And if things go wrong and we *do* panic then the only
      // impact is that the write fails.
      // TODO: This option interface sucks, see if we can rewrite options
      // so we don't have to pattern match on type.
      // Partition the dict into typed dicts?
      // Yeah, then we can ditch the Option value wrapper.
      let assert Ok(interactions.ValueStr(name)) =
        event.options |> dict.get("name")

      let new_ship =
        ship.NewDockedShip(
          name:,
          owner_id: player.discord_id,
          cargo_capacity: 100,
          speed: 10.0,
          location:,
        )

      case ship.insert_ships(conn, [new_ship]) {
        Ok(_) -> {
          logging.log(logging.Debug, "Sold ship to " <> player.discord_id)
          let _ =
            ResponseUpdate("Congratulations on your purchase.") |> followup()
          Ok(Nil)
        }
        Error(e) -> {
          logging.log(
            logging.Error,
            "Unable to insert ship: " <> string.inspect(e),
          )
          let _ = ResponseUpdate("Your ship was lost in transit.") |> followup()
          Error("Unable to insert new ship")
        }
      }
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
fn handle_list_waypoints(state: State, event: InteractionEvent) -> Nil {
  use <- interactions.defer_response(state.bot, event, True)
  use <- catch_deferred_database_error()
  use conn <- connection.with_readonly_connection(state.db)
  // Get a player's ships, if they have any.
  // This command works even for unregistered players and players without ships
  // so we do special handling for the absence of ships.
  let ships = ship.select_ships_for_player(conn, event.user.id)
  // Grab all the waypoints from the database.
  case waypoints.select_all_waypoints(conn), ships {
    // This is the case where the player has ships
    // We just use the first ship returned for now.
    // TODO: Some way to select ship.
    Ok(all_waypoints), Ok([first_ship, ..]) -> {
      let waypoint_strings =
        all_waypoints
        |> list.map(waypoint_to_string(_, first_ship))
        |> string.join("\n")

      interactions.ResponseUpdate("### Waypoints:\n" <> waypoint_strings)
    }
    // Deal with some edgecases that have similar handling
    Ok(all_waypoints), ship_list -> {
      case ship_list {
        Ok([]) -> Nil
        // This is impossible because of the previous check but the compiler doesn't know that
        Ok(ships) ->
          logging.log(
            logging.Error,
            "Got ships but this should have been caught by the outer case:\n"
              <> string.inspect(ships),
          )
        Error(e) ->
          logging.log(
            logging.Error,
            "Unable to fetch ships for player:\n" <> string.inspect(e),
          )
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
fn handle_travel_start(state: State, event: InteractionEvent) -> Nil {
  use <- interactions.defer_response(state.bot, event, True)
  let user = event.user
  use <- catch_deferred_database_error()
  use conn <- connection.with_writable_connection(state.db)
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
          process.send_after(
            state.ship_refresh_actor,
            duration.to_seconds(time) *. 1000.0 +. 100.0
              |> float.ceiling
              |> float.truncate,
            ship.RefreshAll,
          )
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
