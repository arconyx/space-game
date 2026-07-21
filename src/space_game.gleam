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
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import logging
import reki
import space_game/discord/api
import space_game/discord/commands
import space_game/discord/gateway
import space_game/game
import space_game/storage

/// Main entry point
/// This is what `gleam run` calls
pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Debug)

  // Load configuration from environment. Most panic if we can't read them
  let storage_path =
    envoy.get("SPACE_GAME_STORAGE_PATH")
    |> result.unwrap(".storail")
  let assert Ok(discord_id) = envoy.get("SPACE_GAME_DISCORD_APP_ID")
  let assert Ok(discord_token) = envoy.get("SPACE_GAME_DISCORD_TOKEN")
  let assert Ok(guild_id) = envoy.get("SPACE_GAME_TEST_GUILD_ID")

  let writer_name: process.Name(storage.Message) = process.new_name("writer")

  let bot = api.new(id: discord_id, token: discord_token)
  let storage = storage.new_storage(storage_path)

  let registry = reki.new()
  let assert Ok(bot_worker_spec) =
    gateway.create_bot_spec(discord_token, game.input_router(
      _,
      registry,
      bot,
      storage,
      writer_name |> process.named_subject,
    ))

  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(fn() { storage.writer(writer_name, storage) }),
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

  process.sleep_forever()
}
