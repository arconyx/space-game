//// Wrap up some other modules to provide a convenient frontend
//// for starting the bot.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/supervision
import space_game/discord/api
import space_game/discord/gateway
import space_game/discord/interactions.{type InteractionEvent}
import space_game/discord/persistent_state
import stratus

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
) -> Result(
  supervision.ChildSpecification(
    process.Subject(stratus.InternalMessage(gateway.GatewayAction)),
  ),
  api.Error,
) {
  // Ask Discord for the gateway address to connect to.
  // They say we should cache this and use it when reconnecting.
  // However when resuming we should isntead use the resume gateway address
  // supplied in the `Ready` event.
  // TODO: Should this be in the actor initialiser instead?
  case gateway.get_websocket_address(token) {
    Ok(url) -> {
      let gatebuilder =
        gateway.GatewayBuilder(
          url:,
          token:,
          handler: command_handler,
          persistent_state: persistent_state.init(url),
        )

      supervision.worker(fn() { gateway.open(gatebuilder) })
      |> Ok
    }
    Error(e) -> Error(e)
  }
}
