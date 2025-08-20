//// Wrap up some other modules to provide a convenient frontend
//// for starting the bot.

import discord/api
import discord/commands.{type SlashCommand}
import discord/gateway
import discord/interactions.{type InteractionEvent}
import discord/types
import discord/watcher
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import logging

pub type Error {
  Gatehouse(actor.StartError)
  API(api.Error)
}

/// Reexport for convenience.
/// This type would be defined here if it didn't cause circular dependencies.
pub type Bot =
  types.Bot

/// Start the bot and register the given global commands.
///
/// The primary component of the running bot is the gatehouse,
/// which mantains a connection to the Discord gateway over
/// which we receive messages.
pub fn start_bot(
  token: String,
  global_commands: List(SlashCommand),
  command_handler: fn(Bot, InteractionEvent) -> Nil,
) -> Result(Bot, Error) {
  // Get our application id from the server so we don't have to hardcode it
  // This will fail if Discord is unreachable, but if we can't reach Discord
  // then we hardly need the id.
  let id =
    api.request(token, http.Get, "/applications/@me", None)
    |> api.send_and_decode(decode.at(["id"], decode.string))
    |> result.map_error(API)
  use id <- result.try(id)

  // Now we have the ID we can construct the bot object
  // We'll be embedding this into the command handler so we access
  // when dealing with interactions.
  let bot = types.Bot(token: token, id: id)

  // Prepare the gatehouse, responsible for managing the processes
  // that listen for Discord events
  use gh <- result.try(
    construct(token, fn(event) { command_handler(bot, event) })
    |> result.map_error(API),
  )
  logging.log(logging.Debug, "Gatehouse constructed")

  // Actually start listening to Discord
  use _ <- result.try(
    static_supervisor.start(gh) |> result.map_error(Gatehouse),
  )
  logging.log(logging.Info, "Gatehouse started")

  // If we're connected then try register global commands
  // There's a quota on creating there (200/day) so we only
  // give the early sections a chance to fail before we use any.
  // Existing, unchanged, commands should not count towards the quota.
  use _ <- result.try(
    commands.register_global_commands(bot, global_commands)
    |> result.map_error(API),
  )
  logging.log(logging.Debug, "Commands registered")

  Ok(bot)
}

/// Construct the gatehouse. This is an OPT supervisor.
///
/// When started the gatehouse will create and maintain a connection
/// to the Discord websockets gateway.
///
/// The gatehouse supervises the Watcher and the Gateway.
/// When the Gateway fails it is restarted.
/// When the Watcher fails both it and the Gateway are restarted.
///
/// The Watcher exists to hold state that should persist across Gateway
/// restarts. Discord warns that gateway connections may frequently be
/// broken. We embrace this by restarting the gateway process when the connection
/// is interrupted or a reconnect is requested. The watcher supplies state
/// that lets us cleanly resume a connection, but if it isn't available we just
/// do a full reconnect.
fn construct(
  auth_token token: String,
  interaction_handler handler: fn(InteractionEvent) -> Nil,
) -> Result(static_supervisor.Builder, api.Error) {
  let watcher = process.new_name("watcher")
  use url <- result.try(gateway.get_websocket_address(token))

  let gatebuilder =
    gateway.GatewayBuilder(url:, token:, handler:, watcher: watcher)

  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(
    supervision.worker(fn() { watcher.start_watcher(watcher) }),
  )
  |> static_supervisor.add(
    supervision.worker(fn() { gateway.open(gatebuilder) }),
  )
  |> Ok
}
