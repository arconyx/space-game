//// Interactions are Discord commands
////
//// https://discord.com/developers/docs/interactions

import discord/api
import discord/types.{type Bot}
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import utils/timing

/// Discord has a limited set of valid types for command options.
/// We wrap them as `OptionValue` so that we can stick them all
/// in a dictionary together.
pub type OptionValue {
  ValueStr(String)
  ValueInt(Int)
  ValueBool(Bool)
  ValueUser(String)
  ValueChannel(String)
  ValueRole(String)
  ValueMention(String)
  ValueFloat(Float)
}

/// Encapsulates basic information about a Discord user
///
/// The name is our best guess at their nickname/display name
/// in the context the interaction is invoked from. In descending
/// order of precendence:
/// Guild nickname > Global display name > Account username
pub type User {
  User(id: String, name: String)
}

/// An interaction event recieved from Discord
///
/// Discord supplies the commands and options as a nested
/// sequence `List(Dict(String, Any))` where each dict may
/// contain further such lists. We parse this into a command
/// list and dict of options with values.
///
/// e.g.
/// `"/root group subcommand option: value"` ->
/// `["root", "group", "subcommand"]` and `{"option": value}`
/// (using a pythonic dict syntax because gleam lacks one)
pub type InteractionEvent {
  ChatInput(
    event_id: String,
    continuation_token: String,
    user: Option(User),
    command: List(String),
    options: Dict(String, OptionValue),
  )
}

/// Errors encountered when parsing interactions from the
/// `INTERACTION_CREATE` events supplied by Discord
/// into `InteractionEvents` that will be supplied to user
/// interaction handlers.
pub type ParseError {
  UnsupportedInteraction(Int)
  UnsupportedApplicationCommand(Int)
  DecodeError(List(decode.DecodeError))
  SiblingSubcommands
}

/// Parse an interaction event from a Discord gateway event into our local representation.
/// Currently only `chat_input` type application commands (i.e. /slash commands) are supported.
///
/// The Discord syntax is described [here](https://discord.com/developers/docs/interactions/receiving-and-responding#interaction-object)
pub fn parse_event(data: Dynamic) -> Result(InteractionEvent, ParseError) {
  case decode.run(data, decode.at(["type"], decode.int)) {
    // Application command
    Ok(2) ->
      case decode.run(data, decode.at(["data", "type"], decode.int)) {
        // Slash command
        Ok(1) ->
          decode.run(data, decode_chat_input())
          |> result.map_error(DecodeError)
          |> result.try(cook_interaction)
        Ok(i) -> UnsupportedApplicationCommand(i) |> Error
        Error(e) -> DecodeError(e) |> Error
      }
    Ok(i) -> UnsupportedInteraction(i) |> Error
    Error(e) -> DecodeError(e) |> Error
  }
}

/// Decode a Discord user object
fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.string)
  use username <- decode.field("username", decode.string)
  use global_name <- decode.field("global_name", decode.optional(decode.string))
  case global_name {
    Some(global) -> User(id, global)
    None -> User(id, username)
  }
  |> decode.success
}

/// Decode a Discord guild member object
fn member_decoder() -> decode.Decoder(User) {
  // The user field is optional but I think we'll always want it
  use user <- decode.field("user", user_decoder())
  use nick <- decode.optional_field(
    "nick",
    None,
    decode.optional(decode.string),
  )
  case nick {
    Some(nick) -> User(..user, name: nick)
    None -> user
  }
  |> decode.success
}

/// This represents decoded options using the structure presented by Discord
/// We use `flatten_opts` to transform a list of these into a more useful form
///
/// We expect subcommand groups to have a single child that is a `OptSubcommand`
/// but we only enforce this when flattening.
type InternalOpt {
  OptSubcommandGroup(name: String, value: List(InternalOpt))
  OptSubcommand(name: String, value: List(InternalOpt))
  OptProperty(name: String, value: OptionValue)
}

/// Decode a Discord application command interaction data option object
///
/// https://discord.com/developers/docs/interactions/receiving-and-responding#interaction-object-application-command-interaction-data-option-structure
fn decode_option() -> decode.Decoder(InternalOpt) {
  use name <- decode.field("name", decode.string)
  use type_ <- decode.field("type", decode.int)
  case type_ {
    // subcommand
    1 -> {
      use child <- decode.optional_field(
        "options",
        [],
        decode.list(decode_option()),
      )
      OptSubcommand(name, child) |> decode.success
    }
    // subcommand group
    2 -> {
      use child <- decode.optional_field(
        "options",
        [],
        decode.list(decode_option()),
      )
      OptSubcommandGroup(name, child) |> decode.success
    }
    // actual option
    3 -> {
      use v <- decode.field("value", decode.string)
      ValueStr(v) |> OptProperty(name, _) |> decode.success
    }
    4 -> {
      use v <- decode.field("value", decode.int)
      ValueInt(v) |> OptProperty(name, _) |> decode.success
    }
    5 -> {
      use v <- decode.field("value", decode.bool)
      ValueBool(v) |> OptProperty(name, _) |> decode.success
    }
    // user
    6 -> {
      use v <- decode.field("value", decode.string)
      ValueUser(v) |> OptProperty(name, _) |> decode.success
    }
    // channel
    7 -> {
      use v <- decode.field("value", decode.string)
      ValueChannel(v) |> OptProperty(name, _) |> decode.success
    }
    // role
    8 -> {
      use v <- decode.field("value", decode.string)
      ValueRole(v) |> OptProperty(name, _) |> decode.success
    }
    // mentionable
    9 -> {
      use v <- decode.field("value", decode.string)
      ValueMention(v) |> OptProperty(name, _) |> decode.success
    }
    // number
    10 -> {
      use v <- decode.field("value", decode.float)
      ValueFloat(v) |> OptProperty(name, _) |> decode.success
    }
    _ -> decode.failure(OptProperty("", ValueInt(0)), "option")
  }
}

type FlattenedOpts {
  FlattenedOpts(commands: List(String), options: Dict(String, OptionValue))
}

/// Transform the Discord command option structure into something better
fn flatten_options(opts: List(InternalOpt)) -> Result(FlattenedOpts, ParseError) {
  case opts {
    [OptSubcommand(name, children)] | [OptSubcommandGroup(name, children)] -> {
      use inner <- result.try(flatten_options(children))
      FlattenedOpts(..inner, commands: [name, ..inner.commands]) |> Ok
    }
    [] -> FlattenedOpts([], dict.new()) |> Ok
    _ ->
      list.map(opts, fn(o) {
        case o {
          OptSubcommand(..) | OptSubcommandGroup(..) ->
            SiblingSubcommands |> Error
          OptProperty(n, v) -> #(n, v) |> Ok
        }
      })
      |> result.all
      |> result.map(fn(l) { dict.from_list(l) |> FlattenedOpts([], _) })
  }
}

/// Internal type representing the decoded interaction object prior
/// to transformations that make it more useful for our purposes
type RawInteractionEvent {
  RawChatInput(
    event_id: String,
    continuation_token: String,
    user: Option(User),
    member: Option(User),
    root_command: String,
    raw_opts: List(InternalOpt),
  )
}

/// Decode Discord interaction events representing the use of slash commands.
///
/// Notes:
/// - This throws a way a lot of data I see no present use for.
/// - It is the responsiblity of the caller to ensure that the input being decoded
///   is for a slash command and not some other event.
///
/// TODO: Include the `["data", "resolved"]` subfield
fn decode_chat_input() -> decode.Decoder(RawInteractionEvent) {
  use event_id <- decode.field("id", decode.string)
  use continuation_token <- decode.field("token", decode.string)
  // The field is optional but the value isn't, however we want to return None as default
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(user_decoder()),
  )
  use member <- decode.optional_field(
    "member",
    None,
    decode.optional(member_decoder()),
  )
  use root_command <- decode.subfield(["data", "name"], decode.string)
  use raw_opts <- decode.field(
    "data",
    decode.optionally_at(["options"], [], decode.list(decode_option())),
  )
  RawChatInput(
    event_id:,
    continuation_token:,
    user:,
    member:,
    root_command:,
    raw_opts:,
  )
  |> decode.success
}

/// Transform a `RawInteractionEvent` into an `InteractionEvent`
fn cook_interaction(
  raw: RawInteractionEvent,
) -> Result(InteractionEvent, ParseError) {
  use options <- result.try(flatten_options(raw.raw_opts))
  let options =
    FlattenedOpts(..options, commands: [raw.root_command, ..options.commands])
  let user = case raw.user, raw.member {
    Some(user), None | None, Some(user) -> Some(user)
    Some(_user), Some(member) -> {
      // This violates the Discord spec
      logging.log(
        logging.Warning,
        "Got user and guild member in same interaction",
      )
      Some(member)
    }
    None, None -> None
  }
  ChatInput(
    event_id: raw.event_id,
    continuation_token: raw.continuation_token,
    user:,
    command: options.commands,
    options: options.options,
  )
  |> Ok
}

/// Run interaction handler in an independent process
///
/// This immediately spawns an unlinked (independent) process.
/// This process then creates an inner process to run the handler and traps exists
/// such that it can handle errors if the `handler` panics. Currently there is no
/// special error handling beyond logging it but it is planned to return an error message
/// to Discord to alert the user.
///
/// If the process does not run in `timeout` ms it will be stopped. If stopping takes more
/// than `timeout` ms then it will be killed.
///
/// As the outer process is unlinked from the caller this function can panic without
/// the crash propagating to the caller. This avoids taking down the gateway just because
/// processing on a single interaction failed.
///
/// TODO: Use a dynamic supervisor instead of this hacked together stand-in
/// TODO: Send error message to Discord on failure. This may take some redesign as we need
/// the interaction object to send a reply.
pub fn process_independently(
  timeout: Int,
  label: String,
  on_error: fn() -> Nil,
  handler: fn() -> Nil,
) -> Pid {
  use <- process.spawn_unlinked
  use <- timing.timed(label)

  process.trap_exits(True)
  // start the worker
  let child = process.spawn(handler)

  // this selector catches exists
  let exit_selector =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit_msg) {
      case exit_msg.reason {
        process.Normal | process.Killed -> Nil
        process.Abnormal(reason) -> {
          logging.log(
            logging.Error,
            label <> " failed with reason " <> string.inspect(reason),
          )
          on_error()
        }
      }
    })

  // run the selector
  case process.selector_receive(exit_selector, timeout) {
    // Process has exited
    Ok(Nil) -> Nil
    // Timeout reached - order process to shutdown
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        label <> " " <> string.inspect(child) <> " timed out",
      )
      process.send_abnormal_exit(child, "Timeout")
      // If we're taking too long to shutdown kill it
      case process.selector_receive(exit_selector, timeout) {
        Ok(Nil) -> Nil
        Error(Nil) ->
          logging.log(logging.Warning, "Killing " <> string.inspect(child))
      }
    }
  }

  logging.log(logging.Debug, label <> " exited")
}

/// Send a deferred response notification to the server
fn send_deferral(
  bot: Bot,
  event: InteractionEvent,
  ephemeral: Bool,
) -> Result(response.Response(String), api.Error) {
  case ephemeral {
    True -> [
      #("type", json.int(5)),
      #("data", json.object([#("flags", json.int(64))])),
    ]
    False -> [
      #("type", json.int(5)),
      #("data", json.object([#("flags", json.int(0))])),
    ]
  }
  |> json.object()
  |> api.post(
    bot,
    "/interactions/ "
      <> event.event_id
      <> "/"
      <> event.continuation_token
      <> "/callback",
    _,
  )
  |> api.send()
}

/// An edit to the original interaction response
///
/// This is basically a subset of the Discord message object.
/// The structure is the same as for the [edit webhook endpoint](https://discord.com/developers/docs/resources/webhook#edit-webhook-message)
pub type ResponseUpdate {
  ResponseUpdate(content: String)
}

/// Edit the original interaction response
///
/// This is commonly used after deferring the response.
fn edit_response(
  bot: Bot,
  event: InteractionEvent,
  up: ResponseUpdate,
) -> Result(response.Response(String), api.Error) {
  [
    #("content", json.string(up.content)),
    #("embeds", json.array([], json.string)),
  ]
  |> json.object()
  |> api.patch(
    bot,
    "/webhooks/ "
      <> bot.id
      <> "/"
      <> event.continuation_token
      <> "/messages/@original",
    _,
  )
  |> api.send()
}

/// Informs Discord we're processing the response.
///
/// Use this for complicated commands that take some processing.
/// The inner function is safe from the 2500ms timer we enforce on interaction processing
/// as it runs in an unlinked process.
///
/// If you want to do things after returning the final edit to the user,
/// consider spawning another new process.
pub fn defer_response(
  bot: Bot,
  event: InteractionEvent,
  ephemeral: Bool,
  with fun: fn() -> ResponseUpdate,
) -> Nil {
  case send_deferral(bot, event, ephemeral) {
    Ok(_) -> {
      {
        use <- process_independently(15 * 1000, "Deferred response", fn() {
          let _ =
            send_followup(
              bot,
              event,
              FollowupResponse("Internal error", ephemeral),
            )
          Nil
        })
        case edit_response(bot, event, fun()) {
          Ok(_) -> logging.log(logging.Debug, "Deferred response edited")
          Error(e) ->
            logging.log(
              logging.Error,
              "Unable to edit deferred response: " <> string.inspect(e),
            )
        }
      }
      Nil
    }
    Error(e) ->
      logging.log(
        logging.Error,
        "Unable to send deferral: " <> string.inspect(e),
      )
  }
}

pub type StandaloneResponse {
  StandaloneResponse(content: String, ephemeral: Bool)
}

/// Send a response to the user
fn send_response(
  bot: Bot,
  event: InteractionEvent,
  response: StandaloneResponse,
) -> Result(response.Response(String), api.Error) {
  [
    #("type", json.int(4)),
    #(
      "data",
      json.object([
        #("content", json.string(response.content)),
        #("flags", case response.ephemeral {
          True -> json.int(64)

          False -> json.int(0)
        }),
      ]),
    ),
  ]
  |> json.object()
  |> api.post(
    bot,
    "/interactions/ "
      <> event.event_id
      <> "/"
      <> event.continuation_token
      <> "/callback",
    _,
  )
  |> api.send()
}

/// Run a function and return the response to the user.
/// This is the goto function for commands where the response
/// occurs in less than 2.5s.
pub fn with_response(
  bot: Bot,
  event: InteractionEvent,
  with fun: fn() -> StandaloneResponse,
) -> Nil {
  case send_response(bot, event, fun()) {
    Ok(_) -> logging.log(logging.Debug, "Response sent")
    Error(e) ->
      logging.log(
        logging.Error,
        "Error sending response:\n" <> string.inspect(e),
      )
  }
}

pub type FollowupResponse {
  FollowupResponse(content: String, ephemeral: Bool)
}

/// Send a followup message to the user
pub fn send_followup(
  bot: Bot,
  event: InteractionEvent,
  response: FollowupResponse,
) -> Result(response.Response(String), api.Error) {
  [
    #("type", json.int(4)),
    #("content", json.string(response.content)),

    case response.ephemeral {
      True -> #("data", json.object([#("flags", json.int(64))]))

      False -> #("data", json.object([#("flags", json.int(0))]))
    },
  ]
  |> json.object()
  |> api.post(
    bot,
    "/webhooks/ " <> bot.id <> "/" <> event.continuation_token,
    _,
  )
  |> api.send()
}
