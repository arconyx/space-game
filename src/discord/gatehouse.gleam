//// Holds the supervisor responsible for managing the Discord gateway

import discord/gateway.{type Interaction}
import discord/watcher
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import stratus.{type Connection}

/// Construct the gatehouse
/// 
/// When started the gatehouse will create and maintain a connection
/// to the Discord websockets gateway.
pub fn construct(
  token: String,
  interaction_handler: fn(Interaction, Connection) -> Nil,
) {
  let watcher_name = process.new_name("watcher")

  let gatebuilder =
    gateway.GatewayBuilder(
      token: token,
      handler: interaction_handler,
      watcher: watcher_name,
    )

  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(
    supervision.worker(fn() { watcher.start_watcher(watcher_name) }),
  )
  |> static_supervisor.add(
    supervision.worker(fn() { gateway.open(gatebuilder) }),
  )
}
