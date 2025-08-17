//// Holds the supervisor responsible for managing the Discord gateway

import discord/api
import discord/gateway
import discord/interactions.{type InteractionEvent}
import discord/watcher
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result

/// Construct the gatehouse
/// 
/// When started the gatehouse will create and maintain a connection
/// to the Discord websockets gateway.
pub fn construct(
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
