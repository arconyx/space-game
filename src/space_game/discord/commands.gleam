//// Everything you need to define Discord /slash commands.
////
//// When commands are used they trigger interaction events.
//// See `discord/interactions` for functions to handle these.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import space_game/discord/api
import space_game/discord/types.{type Bot}
import utils/non_empty_lists.{type NonEmptyList}

/// The contexts in which a command can be invoked
///
/// These are a combination of three boolean values:
/// - Guilds (servers) for channels in a server
/// - Bot DMs for DMs between the user and the bot
/// - User DMs for DMs between users or group DMs
pub type InteractionContext {
  UseInGuild
  UseInBotDM
  UseInUserDM
  UseInGuildOrBotDM
  UseInGuildOrUserDM
  UseInAnyDM
  UseAnywhere
  // I considered
  // `InteractionContext(guild: Bool, bot_dm: Bool, group_dm: Bool)`
  // but then we can have InteractionContext(false, false, false)
}

fn interaction_context_to_json(ctx: InteractionContext) -> Json {
  case ctx {
    UseInGuild -> [0]
    UseInBotDM -> [1]
    UseInUserDM -> [2]
    UseInGuildOrBotDM -> [0, 1]
    UseInGuildOrUserDM -> [0, 2]
    UseInAnyDM -> [1, 2]
    UseAnywhere -> [0, 1, 2]
  }
  |> json.array(json.int)
}

/// The context in which a command must be installed to be used,
/// regardless of where the interaction is occuring.
///
/// A guild command requires the bot must be installed to one of the user's guilds.
/// A user command requires that the bot must be installed by the user.
///
/// This does NOT affect where the command can be invoked.
pub type InstallContext {
  // See InteractionContext for details on why this implementation was chosen
  // InstallContext(guild: Bool, user: Bool)
  InstallToGuild
  InstallToUser
  InstallEverywhere
}

fn install_context_to_json(ctx: InstallContext) -> Json {
  case ctx {
    InstallToGuild -> [0]
    InstallToUser -> [1]
    InstallEverywhere -> [0, 1]
  }
  |> json.array(json.int)
}

/// Options to be included with the command so the user can supply parameters
///
/// # Not Supported
// - Choices for string/int/num
// - Restricting channel types
// - Min/max string length
// - Autocomplete
pub type CommandOption {
  StringOpt(name: String, description: String)
  IntegerOpt(
    name: String,
    description: String,
    min: Option(Int),
    max: Option(Int),
  )
  BoolOpt(name: String, description: String)
  UserOpt(name: String, description: String)
  ChannelOpt(name: String, description: String)
  RoleOpt(name: String, description: String)
  MentionOpt(name: String, description: String)
  FloatOpt(
    name: String,
    description: String,
    min: Option(Float),
    max: Option(Float),
  )
}

/// Partially transform option to JSON.
/// Just implements the generic fields.
fn skeleton_opt(
  opt: CommandOption,
  type_: Int,
  required: Bool,
) -> List(#(String, Json)) {
  [
    #("type", json.int(type_)),
    #("name", json.string(opt.name)),
    #("description", json.string(opt.description)),
    #("required", json.bool(required)),
  ]
}

/// Prepend an optional value to the list a key-value tuple if the value is not None
fn push_some_value(ls: List(b), value: Option(a), map: fn(a) -> b) -> List(b) {
  case value {
    Some(v) -> [map(v), ..ls]
    None -> ls
  }
}

/// Convert a key and a value to a key-value tuple after
/// transforming the value with the encoder
fn encode_property(key: c, value: a, encoder: fn(a) -> b) -> #(c, b) {
  #(key, encoder(value))
}

fn command_option_to_json(opt: CommandOption, required: Bool) -> Json {
  case opt {
    StringOpt(..) -> skeleton_opt(opt, 3, required)
    IntegerOpt(_, _, min, max) ->
      skeleton_opt(opt, 4, required)
      |> push_some_value(min, encode_property("min_value", _, json.int))
      |> push_some_value(max, encode_property("max_value", _, json.int))
    BoolOpt(..) -> skeleton_opt(opt, 5, required)
    UserOpt(..) -> skeleton_opt(opt, 6, required)
    ChannelOpt(..) -> skeleton_opt(opt, 7, required)
    RoleOpt(..) -> skeleton_opt(opt, 8, required)
    MentionOpt(..) -> skeleton_opt(opt, 9, required)
    FloatOpt(_, _, min, max) ->
      skeleton_opt(opt, 10, required)
      |> push_some_value(min, encode_property("min_value", _, json.float))
      |> push_some_value(max, encode_property("max_value", _, json.float))
  }
  |> json.object
}

/// Subcommands may be either a subcommand, with 0-25 options,
/// or a subcommand group, whose children must be subcommands or
/// subcommand groups.
pub type Subcommands {
  SubcommandGroup(
    cmd: String,
    description: String,
    subcommands: NonEmptyList(Subcommands),
  )
  Subcommand(
    cmd: String,
    description: String,
    required_options: List(CommandOption),
    optional_options: List(CommandOption),
  )
}

fn options_to_json(
  required: List(CommandOption),
  optional: List(CommandOption),
) -> Json {
  list.map(required, command_option_to_json(_, True))
  |> list.append(list.map(optional, command_option_to_json(_, False)))
  |> json.preprocessed_array
}

fn subcommands_to_json(sub: Subcommands) -> Json {
  let base = [
    #("name", json.string(sub.cmd)),
    #("description", json.string(sub.description)),
  ]
  case sub {
    SubcommandGroup(_, _, subcommands) -> [
      #("type", json.int(2)),
      #(
        "options",
        non_empty_lists.map(subcommands, subcommands_to_json)
          |> non_empty_lists.to_list
          |> json.preprocessed_array,
      ),
      ..base
    ]
    Subcommand(_, _, required, optional) -> [
      #("type", json.int(1)),
      #("options", options_to_json(required, optional)),
      ..base
    ]
  }
  |> json.object
}

/// A Discord slash command definition
///
/// `TopLevelCommand`s represent a command with no subcommands.
/// `NestedCommand`s should be used if the command has any subcommands.
/// Discord does not permit the use of the root command if it has any subcommands. 
pub type SlashCommand {
  TopLevelCommand(
    cmd: String,
    // Optional according to Discord, but we require it to enforce good practice
    description: String,
    install_context: InstallContext,
    interaction_contexts: InteractionContext,
    required_options: List(CommandOption),
    optional_options: List(CommandOption),
  )
  NestedCommand(
    cmd: String,
    description: String,
    install_context: InstallContext,
    interaction_contexts: InteractionContext,
    subcommands: List(Subcommands),
  )
}

fn slash_command_to_json(cmd: SlashCommand) -> Json {
  let opts = case cmd {
    TopLevelCommand(required_options:, optional_options:, ..) ->
      options_to_json(required_options, optional_options)
    NestedCommand(subcommands:, ..) ->
      list.map(subcommands, subcommands_to_json) |> json.preprocessed_array
  }
  [
    #("name", cmd.cmd |> json.string),
    #("description", cmd.description |> json.string),
    #("integration_types", cmd.install_context |> install_context_to_json),
    #("contexts", cmd.interaction_contexts |> interaction_context_to_json),
    #("options", opts),
    #("type", json.int(1)),
  ]
  |> json.object
}

/// Register global commands with Discord.
///
/// > Global commands are available for every guild that adds your app.
/// > An individual app's global commands are also available in DMs if
/// > that app has a bot that shares a mutual guild with the user.
///
/// There is a global rate limit of 200 application command creates per day, per guild.
/// However commands defined though this method should not count towards the rate limit
/// if they are already registered and their specification is unchanged.
///
/// There may be some latency before the new commands become available.
pub fn register_global_commands(
  bot: Bot,
  cmds: List(SlashCommand),
) -> Result(Nil, api.Error) {
  case cmds {
    [] -> Ok(Nil)
    _ ->
      list.map(cmds, slash_command_to_json)
      |> json.preprocessed_array
      |> api.put(bot, "/applications/" <> bot.id <> "/commands", _)
      |> api.send
      |> result.replace(Nil)
  }
}

/// Register a command to a guild.
/// 
/// > Guild commands are specific to the guild you specify when making them.
/// > Guild commands are not available in DMs.
///
/// These are subject to the same rate limits as `register_global_commands`.
/// They update instantly, which makes then ideal for testing.
pub fn register_guild_commands(
  bot: Bot,
  guild: String,
  cmds: List(SlashCommand),
) -> Result(Nil, api.Error) {
  case cmds {
    [] -> Ok(Nil)
    _ ->
      list.map(cmds, slash_command_to_json)
      |> json.preprocessed_array
      |> api.put(
        bot,
        "/applications/" <> bot.id <> "/guilds/" <> guild <> "/commands",
        _,
      )
      |> api.send
      |> result.replace(Nil)
  }
}
