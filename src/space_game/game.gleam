import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import logging
import reki
import space_game/discord/api
import space_game/discord/commands.{
  type SlashCommand, NestedCommand, Subcommand, TopLevelCommand,
}
import space_game/discord/formatting
import space_game/discord/interactions.{
  type InteractionEvent, ResponseUpdate, StandaloneResponse,
}
import space_game/game/ship
import space_game/storage
import space_game/utils/debug
import storail

pub type Message {
  Interaction(InteractionEvent)
  RefreshPosition
}

type State {
  State(
    player: storage.Player,
    // Just embed the bot in the interaction?
    bot: api.Bot,
    storage: storage.Storage,
    writer: process.Subject(storage.Message),
    self: process.Subject(Message),
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
          cmd: "name",
          description: "Name your ship",
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

/// Create an actor for a user, loading state from storage
fn make_user_actor(
  discord_id: String,
  bot: api.Bot,
  storage: storage.Storage,
  writer: process.Subject(storage.Message),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    case storage.get_player(discord_id, storage) {
      Ok(player) ->
        State(player:, bot:, storage:, writer:, self: subject)
        |> actor.initialised()
        |> actor.returning(subject)
        |> Ok
      Error(storail.ObjectNotFound(..)) -> "Player not found" |> Error
      Error(e) -> {
        logging.log(
          logging.Error,
          "Unable to load player data for player "
            <> discord_id
            <> " due to error: "
            <> storage.storail_error_to_string(e),
        )
        "Unable to load player data"
        |> Error
      }
    }
  })
  |> actor.on_message(command_handler)
  |> actor.start()
  |> debug.log_ok(logging.Debug, "Started actor for user " <> discord_id)
  |> result.map(fn(actor_start) {
    process.send_after(actor_start.data, 3000, RefreshPosition)
    actor_start
  })
}

fn make_user_actor_for_new_player(
  discord_id: String,
  bot: api.Bot,
  storage: storage.Storage,
  writer: process.Subject(storage.Message),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  // Spawn new players at the first waypoint in the list
  let position = case storage.all_waypoints {
    [] -> "No waypoints exist" |> actor.InitFailed |> Error
    [waypoint, ..] -> storage.Docked(at: waypoint.id) |> Ok
  }
  use position <- result.try(position)

  let player =
    storage.Player(
      discord_id:,
      account_balance: 40_000,
      ship: storage.Ship(
        // TODO: Randomise ship name
        name: "Duckling",
        cargo_capacity: 100,
        speed: 10,
        cargo: [],
        position:,
        value: 60_000,
      ),
    )

  actor.new_with_initialiser(1000, fn(subject) {
    State(player:, bot:, storage:, writer:, self: subject)
    |> actor.initialised()
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(command_handler)
  |> actor.start()
  |> debug.log_ok(logging.Debug, "Started actor for new user " <> discord_id)
}

pub fn input_router(
  event: interactions.InteractionEvent,
  registry: reki.Registry(String, Message),
  bot: api.Bot,
  storage: storage.Storage,
  writer: process.Subject(storage.Message),
) -> Nil {
  // TODO: Handle errors
  let _ =
    reki.lookup_or_start(registry, event.user.id, make_user_actor(
      _,
      bot,
      storage,
      writer,
    ))
    |> result.lazy_or(fn() {
      reki.lookup_or_start(
        registry,
        event.user.id,
        make_user_actor_for_new_player(_, bot, storage, writer),
      )
    })
    |> result.map(process.send(_, Interaction(event)))

  Nil
}

type StateChange {
  UpdateState(State)
  NoChange
}

/// Route commands to handler functions
fn command_handler(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let state_update = case message {
    Interaction(event) ->
      case event {
        // Handle /commands
        // This is future proofing against supporting more command types
        interactions.ChatInput(command:, ..) ->
          case command {
            ["account", "balance"] -> handle_balance_check(state, event)
            ["ship", "name"] -> handle_ship_naming(state, event)
            ["ship", "travel"] -> handle_travel_start(state, event)
            ["waypoints"] -> handle_list_waypoints(state, event)
            [] -> {
              logging.log(logging.Warning, "Empty command string")
              NoChange
            }
            cmd -> {
              logging.log(
                logging.Warning,
                "Unhandled command: /" <> string.join(cmd, " "),
              )
              NoChange
            }
          }
      }
    RefreshPosition -> refresh_position(state)
  }
  case state_update {
    UpdateState(new_state) -> {
      logging.log(
        logging.Debug,
        "Registered state change for player " <> new_state.player.discord_id,
      )
      process.send(new_state.writer, storage.WritePlayer(new_state.player))
      actor.continue(new_state)
    }
    NoChange -> actor.continue(state)
  }
}

fn refresh_position(state: State) -> StateChange {
  let ship = state.player.ship
  case ship.position {
    storage.Docked(..) -> NoChange
    storage.Travelling(origin:, destination:, departed:) ->
      case storage.get_waypoint(origin), storage.get_waypoint(destination) {
        Ok(origin), Ok(destination) -> {
          // TODO: Why don't we just do a time comparison
          // Hell, why aren't we storing expected arrival times in the travel
          // object?
          let travel_time = ship.travel_time(origin, destination, ship)
          let arrival_time = timestamp.add(departed, travel_time)
          let now = timestamp.system_time()
          case timestamp.compare(now, arrival_time) {
            order.Gt | order.Eq -> {
              let new_state =
                State(
                  ..state,
                  player: storage.Player(
                    ..state.player,
                    ship: storage.Ship(
                      ..ship,
                      position: storage.Docked(destination.id),
                    ),
                  ),
                )
              logging.log(
                logging.Debug,
                "Refreshed position for player " <> state.player.discord_id,
              )
              UpdateState(new_state)
            }
            _ -> {
              timestamp.difference(now, arrival_time)
              |> duration.to_milliseconds()
              |> process.send_after(state.self, _, RefreshPosition)
              logging.log(
                logging.Debug,
                "Delayed position refresh for player "
                  <> state.player.discord_id,
              )
              NoChange
            }
          }
        }
        _, _ -> {
          logging.log(
            logging.Warning,
            "Unable to refresh ship because we could not resolve at least one waypoint.",
          )
          NoChange
        }
      }
  }
}

/// Print the user's account balance
fn handle_balance_check(state: State, event: InteractionEvent) -> StateChange {
  let _ =
    StandaloneResponse(
      "You have "
        <> int.to_string(state.player.account_balance)
        <> " credits in your account.",
      True,
    )
    |> interactions.send_response(state.bot, event, _)
  NoChange
}

fn handle_ship_naming(state: State, event: InteractionEvent) -> StateChange {
  // The assert is safe here because Discord enforces that the option is
  // present. And if things go wrong and we *do* panic then the only
  // impact is that the write fails.
  // TODO: This option interface sucks, see if we can rewrite options
  // so we don't have to pattern match on type.
  // Partition the dict into typed dicts?
  // Yeah, then we can ditch the Option value wrapper.
  let assert Ok(interactions.ValueStr(name)) = event.options |> dict.get("name")

  let new_state =
    State(
      ..state,
      player: storage.Player(
        ..state.player,
        ship: storage.Ship(..state.player.ship, name:),
      ),
    )

  let _ =
    StandaloneResponse("Ship renamed to " <> name, ephemeral: True)
    |> interactions.send_response(state.bot, event, _)

  UpdateState(new_state)
}

/// Print a list of waypoints with travel time information
fn handle_list_waypoints(state: State, event: InteractionEvent) -> StateChange {
  // TODO: Unwrap deferred block
  {
    use <- interactions.defer_response(state.bot, event, True)

    // Sort waypoints by distance from where we're docked (or our destination)
    let current_position =
      case state.player.ship.position {
        storage.Docked(at:) -> at
        storage.Travelling(destination:, ..) -> destination
      }
      |> storage.get_waypoint()
    let waypoints = case current_position {
      Ok(pos) ->
        storage.all_waypoints
        |> list.sort(fn(a, b) {
          duration.compare(
            ship.travel_time(pos, a, state.player.ship),
            ship.travel_time(pos, b, state.player.ship),
          )
        })
      Error(_) -> storage.all_waypoints
    }

    // Convert waypoints into an bulletpointed string
    waypoints
    |> list.map(fn(waypoint) {
      "- "
      <> waypoint.name
      <> " ["
      <> int.to_string(waypoint.pos_x)
      <> ", "
      <> int.to_string(waypoint.pos_y)
      <> "]"
      <> case state.player.ship.position {
        storage.Docked(at:) if at == waypoint.id -> " (docked)"
        storage.Travelling(origin:, ..) if origin == waypoint.id -> " (origin)"
        storage.Travelling(origin:, destination:, departed:)
          if destination == waypoint.id
        ->
          " (arriving "
          <> storage.get_waypoint(origin)
          |> result.map(fn(origin) {
            ship.travel_time(origin, waypoint, state.player.ship)
            |> timestamp.add(departed, _)
            |> formatting.relative_timestamp()
          })
          |> result.unwrap("???")
          <> ")"
        _ -> ""
      }
    })
    |> string.join("\n")
    |> string.append(suffix: _, to: "### Waypoints\n")
    |> ResponseUpdate
  }

  // If this function is called players might checking ship position, so we'll
  // queue a refresh to bring it up to date. This will only affect subsequent
  // commands.
  case state.player.ship.position {
    storage.Docked(..) -> Nil
    storage.Travelling(..) -> process.send(state.self, RefreshPosition)
  }

  NoChange
}

/// Tell a ship to fly to a waypoint.
fn handle_travel_start(state: State, event: InteractionEvent) -> StateChange {
  let _ = interactions.send_deferral(state.bot, event, True)
  // TODO: Better option handling
  let assert Ok(interactions.ValueStr(name)) =
    event.options |> dict.get("destination")
  // Find the waypoint and the ship
  case storage.get_waypoint_by_name(name) {
    Ok(destination) ->
      case state.player.ship.position {
        storage.Docked(at:) -> {
          let position =
            storage.Travelling(
              origin: at,
              destination: destination.id,
              departed: timestamp.system_time(),
            )
          let state =
            State(
              ..state,
              player: storage.Player(
                ..state.player,
                ship: storage.Ship(..state.player.ship, position:),
              ),
            )
          let arrival_time_str =
            storage.get_waypoint(at)
            |> result.map(fn(origin) {
              let time =
                ship.travel_time(origin, destination, state.player.ship)
              process.send_after(
                state.self,
                duration.to_milliseconds(time),
                RefreshPosition,
              )
              timestamp.add(position.departed, time)
              |> formatting.relative_timestamp()
            })
            |> result.unwrap("???")
          let _ =
            ResponseUpdate(
              "Departing for "
              <> destination.name
              <> ". Arriving in "
              <> arrival_time_str,
            )
            |> interactions.edit_response(state.bot, event, _)

          UpdateState(state)
        }
        storage.Travelling(..) -> {
          let _ =
            ResponseUpdate(
              "You must reach your current destination before you can chart a new course.",
            )
            |> interactions.edit_response(state.bot, event, _)
          NoChange
        }
      }
    Error(_) -> {
      let _ =
        ResponseUpdate("Unable to find a waypoint called " <> name)
        |> interactions.edit_response(state.bot, event, _)
      NoChange
    }
  }
}
