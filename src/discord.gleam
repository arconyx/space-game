//// Wrapper methods for interaction with Discord

import discord_gleam
import discord_gleam/event_handler.{type Packet}
import discord_gleam/types/bot.{type Bot}
import discord_gleam/ws/packets/interaction_create.{type InteractionCreatePacket}
import gleam/string
import logging

/// Take arbitary gateaway events and do something in response to them
/// Currently only processes InteractionCreatePackets, as sent by application commands
/// 
/// See https://discord.com/developers/docs/events/gateway-events#receive-events
fn handle_event(
  bot: Bot,
  packet: Packet,
  command_handler: fn(Bot, InteractionCreatePacket) -> Nil,
) -> Nil {
  case packet {
    event_handler.InteractionCreatePacket(interaction) ->
      command_handler(bot, interaction)
    packet ->
      logging.log(logging.Debug, "Unhandled packet: " <> string.inspect(packet))
  }
}

pub fn start_bot(
  bot: Bot,
  command_handler: fn(Bot, InteractionCreatePacket) -> Nil,
) -> Nil {
  let event_handler = [
    fn(bot, packet) { handle_event(bot, packet, command_handler) },
  ]

  discord_gleam.run(bot, event_handler)
}
