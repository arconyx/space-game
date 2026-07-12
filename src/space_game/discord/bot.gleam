//// Wrap up some other modules to provide a convenient frontend
//// for starting the bot.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import space_game/discord/api
import space_game/discord/gateway
import space_game/discord/interactions.{type InteractionEvent}
import space_game/discord/watcher

pub type Error {
  Gatehouse(actor.StartError)
  API(api.Error)
}

/// Construct an OTP supervisor tree for the bot
///
/// This handles maintaining a websockets connection to the
/// Discord gateway, over which we receive interactions when
/// users use commands.
/// 
/// This can error when we are unable to retrieve the websocket
/// address for the gateway.
pub fn create(
  token: String,
  command_handler: fn(InteractionEvent) -> Nil,
) -> Result(static_supervisor.Builder, api.Error) {
  // Ask Discord for the gateway address to connect to.
  // They say we should cache this and use it when reconnecting.
  // However when resuming we should isntead use the resume gateway address
  // supplied in the `Ready` event.
  // TODO: Should this be in the actor initialiser instead?
  case gateway.get_websocket_address(token) {
    Ok(url) -> {
      // TODO: We really shouldn't be creating an atom in a supervisor
      let watcher = process.new_name("watcher")
      let gatebuilder =
        gateway.GatewayBuilder(
          url:,
          token:,
          handler: command_handler,
          watcher: watcher,
        )

      // When the Gateway fails it is restarted.
      // When the Watcher fails both it and the Gateway are restarted.
      static_supervisor.new(static_supervisor.RestForOne)
      |> static_supervisor.add(
        // The Watcher exists to hold state that should persist across Gateway
        // restarts. Discord warns that gateway connections may frequently be
        // broken. We embrace this by restarting the gateway process when the connection
        // is interrupted or a reconnect is requested. The watcher supplies state
        // that lets us cleanly resume a connection, but if it isn't available we just
        // do a full reconnect.
        supervision.worker(fn() { watcher.start_watcher(watcher) }),
      )
      |> static_supervisor.add(
        supervision.worker(fn() { gateway.open(gatebuilder) }),
      )
      |> Ok
    }
    Error(e) -> Error(e)
  }
}
