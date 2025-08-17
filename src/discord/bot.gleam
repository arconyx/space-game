import discord/api
import discord/commands.{type SlashCommand}
import discord/gatehouse
import discord/interactions.{type InteractionEvent}
import discord/types
import gleam/dynamic/decode
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import logging

pub type Error {
  Gatehouse(actor.StartError)
  API(api.Error)
}

pub type Bot =
  types.Bot

pub fn start_bot(
  token: String,
  commands: List(SlashCommand),
  command_handler: fn(Bot, InteractionEvent) -> Nil,
) -> Result(Bot, Error) {
  use id <- result.try(get_id(token) |> result.map_error(API))
  let bot = types.Bot(token: token, id: id)

  use gh <- result.try(
    gatehouse.construct(token, fn(event) { command_handler(bot, event) })
    |> result.map_error(API),
  )
  logging.log(logging.Debug, "Gatehouse constructed")

  use _ <- result.try(
    static_supervisor.start(gh) |> result.map_error(Gatehouse),
  )
  logging.log(logging.Info, "Gatehouse started")

  use _ <- result.try(
    commands.register_global_commands(bot, commands) |> result.map_error(API),
  )
  logging.log(logging.Debug, "Commands registered")

  Ok(bot)
}

fn get_id(token: String) -> Result(String, api.Error) {
  api.get_with_token(token, "/applications/@me")
  |> api.send_and_decode(decode.at(["id"], decode.string))
}
