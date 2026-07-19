//// Main entrypoint for space game
//// 
//// # Environment Variables
//// 
//// ## SPACE_GAME_DATABASE PATH
//// Path to sqlite database.
//// *Default: "space-game.sqlite3"* 
//// 
//// ## SPACE_GAME_DISCORD_APP_ID
//// The application id for the Discord bot.
//// Found in `Overview > General Information > Application ID`
//// on the Discord application page.
//// 
//// ## SPACE_GAME_DISCORD_TOKEN
//// Discord bot authorisation token.
//// Found in `Overview > Bot > Token` on the Discord application
//// page.
////
//// ## SPACE_GAME_TEST_GUILD_ID
//// Server ID used to register guild commands in test code.
//// Enable dev mode in Discord's advanced settings, then right click
//// on the server icon to obtain it.

import envoy
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import reki
import space_game/database/setup
import space_game/database/write
import space_game/discord/api
import space_game/discord/commands
import space_game/discord/gateway
import space_game/discord/interactions
import space_game/game
import space_game/game/goods
import space_game/game/player
import space_game/game/ship
import space_game/game/waypoints
import sqlight

/// Main entry point
/// This is what `gleam run` calls
pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  // Load configuration from environment. Most panic if we can't read them
  let database_path =
    envoy.get("SPACE_GAME_DATABASE_PATH")
    |> result.unwrap("space-game.sqlite3")
  let assert Ok(discord_id) = envoy.get("SPACE_GAME_DISCORD_APP_ID")
  let assert Ok(discord_token) = envoy.get("SPACE_GAME_DISCORD_TOKEN")
  let assert Ok(guild_id) = envoy.get("SPACE_GAME_TEST_GUILD_ID")

  let ship_refresh_name: process.Name(ship.Message) = process.new_name("ships")
  let db_writer_name: process.Name(write.Message) = process.new_name("writer")

  let bot = api.new(id: discord_id, token: discord_token)

  let user_process_template =
    game.make_user_actor(
      bot,
      database_path,
      process.named_subject(db_writer_name),
      process.named_subject(ship_refresh_name),
      goods.goods_dict(goods.all_goods),
    )

  case setup.init_database(database_path, define_tables) {
    Ok(Nil) -> logging.log(logging.Debug, "Database initialised")
    Error(e) ->
      panic as { "Unable to initalise database: " <> string.inspect(e) }
  }

  let registry = reki.new()

  let assert Ok(bot_worker_spec) =
    gateway.create_bot_spec(discord_token, input_router(
      _,
      registry,
      user_process_template,
    ))

  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(fn() {
        write.create_writer(db_writer_name, database_path)
      }),
    )
    |> static_supervisor.add(
      supervision.worker(ship.make_ship_worker(
        ship_refresh_name,
        db_writer_name,
        6 * 60 * 1000,
      )),
    )
    |> static_supervisor.add(reki.supervised(registry))
    |> static_supervisor.add(bot_worker_spec)
    |> static_supervisor.start()

  // Normally we'd register global commands but for testing 
  // we're using guild args because they update faster and
  // don't have a quota
  let assert Ok(_) =
    commands.register_global_commands(bot, [])
    |> result.map_error(fn(e) {
      "Unable to register global commands due to error:\n"
      <> api.error_to_string(e)
    })
  logging.log(logging.Debug, "Global commands registered")

  let assert Ok(_) =
    commands.register_guild_commands(bot, guild_id, game.define_commands())
    |> result.map_error(fn(e) {
      "Unable to register guild commands for guild "
      <> guild_id
      <> " due to error:\n"
      <> api.error_to_string(e)
    })
  logging.log(logging.Debug, "Guild commands registered for guild " <> guild_id)

  let _ = waypoints.demo_waypoint(database_path)

  process.sleep_forever()
}

/// Declare database tables
fn define_tables(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  use _ <- result.try(waypoints.create_waypoints_table(conn))
  use _ <- result.try(player.create_players_table(conn))
  ship.create_ships_table(conn)
}

fn input_router(
  event: interactions.InteractionEvent,
  registry: reki.Registry(String, game.Message),
  template: fn(String) ->
    Result(actor.Started(process.Subject(game.Message)), actor.StartError),
) -> Nil {
  // TODO: Handle errors
  let _ =
    reki.lookup_or_start(registry, event.user.id, template)
    |> result.map(fn(subject) { process.send(subject, game.Interaction(event)) })
  Nil
}
