//// Wrap up some other modules to provide a convenient frontend
//// for starting the bot.

import discord/api
import discord/commands.{type SlashCommand}
import discord/gatehouse
import discord/interactions.{type InteractionEvent}
import discord/types
import gleam/dynamic/decode
import gleam/http
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import logging

pub type Error {
  Gatehouse(actor.StartError)
  API(api.Error)
}

/// Reexport for convenience
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
    gatehouse.construct(token, fn(event) { command_handler(bot, event) })
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
