//// Wrap up some other modules to provide a convenient frontend
//// for starting the bot.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import logging
import space_game/discord/api
import space_game/discord/gateway
import space_game/discord/interactions.{type InteractionEvent}
import space_game/discord/watcher

pub type Error {
  Gatehouse(actor.StartError)
  API(api.Error)
}

/// Start the bot and register the given global commands.
///
/// The primary component of the running bot is the gatehouse,
/// which mantains a connection to the Discord gateway over
/// which we receive messages.
pub fn start_bot(
  token: String,
  command_handler: fn(InteractionEvent) -> Nil,
) -> Result(Nil, Error) {
  // Prepare the gatehouse, responsible for managing the processes
  // that listen for Discord events
  use gh <- result.try(
    construct(token, fn(event) { command_handler(event) })
    |> result.map_error(API),
  )
  logging.log(logging.Debug, "Gatehouse constructed")

  // Actually start listening to Discord
  use _ <- result.try(
    static_supervisor.start(gh) |> result.map_error(Gatehouse),
  )
  logging.log(logging.Info, "Gatehouse started")

  Ok(Nil)
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
