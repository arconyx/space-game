//// Handle connections to the Discord websockets gateway
////
//// The primary method of talking to Discord is over a websockets connection
//// via what they call the gateway. Relevant documentation includes [general guidance](https://discord.com/developers/docs/events/gateway)
//// and [gateway events information](https://discord.com/developers/docs/events/gateway-events).
////
//// This module is responsible for providing the underpinnings for interacting with the
//// gateway. We use the `stratus` library to handle the actual websockets protocol, but
//// everything Discord related is our responsibility.
////
//// Stratus spawns an actor running an event loop we provide. We communicate with the loop
//// in the normal erlang OTP way - that is by sending messages to it.

import discord/api
import discord/interactions.{type InteractionEvent}
import discord/watcher.{type ResumeState}
import gleam/dynamic/decode.{type Dynamic}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/float
import gleam/http/request
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gramps/websocket
import logging
import stratus.{
  type Connection, type InternalMessage, type Message, type Next,
  type SocketReason,
}
import timing

/// Actions to be performed by the gateway
///
/// This is a standard OTP style message type, but named action
/// to avoid confusion with Discord messages.
///
/// Communicate with the gateway by passing it objects of this type
/// using `process.send` or `process.call` from `gleam/erlang/process`
pub type GatewayAction {
  Close
  SendHeartbeat
  IsReady(Subject(Bool))
}

/// Internal state of the gateway
/// 
/// Heartbeat interval is in milliseconds
pub type GatewayState {
  GatewayState(
    token: String,
    resume: Option(ResumeState),
    watcher: Subject(watcher.Message),
    self: Subject(GatewayAction),
    // we need this for heartbeats as well as resuming
    sequence: Option(Int),
    heartbeat_acknowledged: Bool,
    ready: Bool,
  )
}

type Error {
  JsonParse(json.DecodeError)
}

pub type Gateway {
  Gateway(pid: Pid, subject: Subject(InternalMessage(GatewayAction)))
}

/// Everything we need to know to start a gateway
/// 
/// The token is a Discord auth token
/// The handler is a function that accepts and processes interactions (i.e. /commands)
pub type GatewayBuilder {
  GatewayBuilder(
    url: String,
    token: String,
    handler: fn(InteractionEvent) -> Nil,
    watcher: Name(watcher.Message),
  )
}

/// Get websockets address used to connect to Discord
/// 
/// Discord supplies the address in the response to a GET
pub fn get_websocket_address(token: String) -> Result(String, api.Error) {
  api.get_with_token(token, "/gateway/bot")
  |> api.send_and_decode(decode.at(["url"], decode.string))
}

/// Open a connection to Discord using their Gateway protocol
/// over websockets
/// 
/// This function will panic if the watcher is unavailable
pub fn open(gateway: GatewayBuilder) {
  let watcher_subj = process.named_subject(gateway.watcher)
  let resume = process.call(watcher_subj, 100, watcher.Get)

  // Get the url Discord wants us to connect to, using the resume
  // address if set
  let url = case resume {
    Some(r) -> r.url
    None -> gateway.url
  }

  // Gleam chokes on 'ws' and 'wss' prefixes
  // We deliberately upgrade ws/http to wss/https because eww unencrypted connection
  let url =
    url
    |> string.replace("wss://", "https://")
    |> string.replace("ws://", "https://")
  let req =
    request.to(url <> "?v=10&encoding=json")
    |> result.replace_error(actor.InitFailed(
      "Unable to parse websocket url " <> url,
    ))
  use req <- result.try(req)
  let req = req |> api.default_headers

  logging.log(logging.Debug, "Websocket request ready")

  stratus.new_with_initialiser(request: req, init: fn() {
    // We use this to pass messages to the gateway from inside the gateway
    let self: Subject(GatewayAction) = process.new_subject()
    let _ =
      process.spawn(fn() {
        process.sleep(5000)
        case process.call(self, 500, IsReady) {
          True -> logging.log(logging.Debug, "Kill switch disarmed")
          False -> {
            logging.log(logging.Warning, "Kill switch triggered")
            panic
          }
        }
      })
    GatewayState(gateway.token, resume, watcher_subj, self, None, True, False)
    |> stratus.initialised()
    |> stratus.selecting(process.new_selector() |> process.select(self))
    |> Ok
  })
  |> stratus.on_message(fn(state, msg, conn) {
    handle_messages(state, msg, conn, gateway.handler)
  })
  |> stratus.on_close(on_close)
  |> stratus.start()
  |> result.map_error(fn(e) {
    case e {
      stratus.HandshakeFailed(handshake_error) ->
        actor.InitFailed(
          "Handshake failed:\n" <> string.inspect(handshake_error),
        )
      stratus.FailedToTransferSocket(reason) ->
        actor.InitFailed("Socket transfer failed:\n" <> string.inspect(reason))
      stratus.ActorFailed(start_error) -> start_error
    }
  })
  |> result.map(fn(r) {
    logging.log(logging.Debug, "Gateway started")
    r
  })
}

/// Handle when the connection is closed without us requesting it
/// 
/// This function will panic when the close code suggests reconnection should
/// be avoided.
fn on_close(state: GatewayState, reason: Option(websocket.CloseReason)) {
  case reason {
    Some(reason) ->
      case reason {
        websocket.NotProvided ->
          logging.log(logging.Info, "Gateway closed by Discord without reason")
        websocket.CustomCloseReason(code, _) -> {
          // TODO: Panics don't kill the supervisor, so we may want to explicitly kill it
          case code {
            4000 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: unknown error",
              )
            4001 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: invalid opcode",
              )
            4002 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: decode error",
              )
            4003 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: not authenticated",
              )
            4004 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: authentication failed",
              )
            4005 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: already authenticated",
              )
            4007 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: invalid sequence",
              )
            4008 ->
              logging.log(
                logging.Warning,
                "Discord closed gateway: rate limited",
              )
            4009 ->
              logging.log(logging.Warning, "Discord closed gateway: timed out")
            4011 -> {
              logging.log(
                logging.Critical,
                "Discord closed gateway: sharding required",
              )
              panic as "Sharding required"
            }
            4012 -> {
              logging.log(
                logging.Critical,
                "Discord closed gateway: invalid api version",
              )
              panic as "Invalid API version"
            }
            4013 -> {
              logging.log(
                logging.Critical,
                "Discord closed gateway: invalid intent",
              )
              panic as "Invalid intent"
            }
            4014 -> {
              logging.log(
                logging.Critical,
                "Discord closed gateway: disallowed intent",
              )
              panic as "Disallowed intent"
            }
            _ -> {
              logging.log(
                logging.Warning,
                "Discord closed gateway: " <> int.to_string(code),
              )
            }
          }
        }
        _ -> {
          process.send(state.watcher, watcher.Clear)
          logging.log(
            logging.Info,
            "Gateway closed by Discord with indication not to resume: "
              <> string.inspect(reason),
          )
        }
      }
    None -> logging.log(logging.Warning, "Gateway closed unexpectedly")
  }
}

/// Top level handler for messages recieved by the stratus actor
/// 
/// These may be websocket messages received from the server (Text, Binary)
/// or user supplied messages (instructions) sent locally (User)
fn handle_messages(
  state: GatewayState,
  msg: Message(GatewayAction),
  conn: Connection,
  interaction_handler: fn(InteractionEvent) -> Nil,
) -> Next(GatewayState, GatewayAction) {
  case msg {
    stratus.Text(text) ->
      handle_text_message(state, text, conn, interaction_handler)
    stratus.User(usr_msg) -> handle_user_message(state, usr_msg, conn)
    // It would be cool to support this format (Erlang External Term Format)
    stratus.Binary(..) -> {
      logging.log(logging.Warning, "Got unsupported binary message")
      stratus.continue(state)
    }
  }
}

/// Handle messages (GatewayAction) sent by the user to the actor
///
/// This handles, for instance, sending events to Discord
fn handle_user_message(
  state: GatewayState,
  msg: GatewayAction,
  conn: Connection,
) -> Next(GatewayState, GatewayAction) {
  case msg {
    Close -> {
      let _ =
        stratus.close_with_reason(conn, stratus.GoingAway(<<"bot shutdown">>))
      logging.log(logging.Info, "Gateway stopped due to CLOSE")
      stratus.stop()
    }
    SendHeartbeat -> beat_heart(state, conn)
    IsReady(client) -> {
      process.send(client, state.ready)
      stratus.continue(state)
    }
  }
}

/// A Discord gateway event, minimally parsed
/// 
/// See [Discord documentation](https://discord.com/developers/docs/events/gateway-events)
type InboundEvent {
  Dispatch(data: Dynamic, sequence: Int, name: String)
  HeartbeatRequest
  Reconnect
  InvalidSession(resume: Bool)
  Hello(heartbeat_interval: Int)
  HeartbeatAck
}

/// Handle text messages received from Discord
fn handle_text_message(
  state: GatewayState,
  msg: String,
  conn: Connection,
  interaction_handler: fn(InteractionEvent) -> Nil,
) -> Next(GatewayState, GatewayAction) {
  // logging.log(logging.Debug, "Got message:\n" <> msg)
  case parse_text_message(msg) {
    Ok(Dispatch(data, sequence, name)) -> {
      // Update state in watcher
      process.send(state.watcher, watcher.UpdateSequence(sequence))
      handle_dispatch(data, name, state.watcher, interaction_handler)
      // Update sequence for heartbeat purposes
      let state = GatewayState(..state, sequence: Some(sequence))
      stratus.continue(state)
    }
    Ok(HeartbeatRequest) -> beat_heart(state, conn)
    // reconnecting may involve a resume https://discord.com/developers/docs/events/gateway#resuming
    // This will probably be a "set flag then terminate", allowing the supervisor to bring it back up
    // Yet another point for a second actor just hosting state
    Ok(Reconnect) -> reconnect_and_resume(conn)
    Ok(InvalidSession(resume)) ->
      case resume {
        True -> {
          logging.log(
            logging.Warning,
            "Invalid session reported, resume requested",
          )
          reconnect_and_resume(conn)
        }
        False -> {
          logging.log(
            logging.Warning,
            "Invalid session reported, full reconnect requested",
          )
          let _ = stratus.close(conn)
          process.send(state.watcher, watcher.Clear)
          stratus.stop()
        }
      }
    // Respond with identify
    Ok(Hello(heartbeat_interval)) -> {
      logging.log(logging.Debug, "Got hello from Discord")
      // If we're resuming send a resume instead of an identify
      let handshake = case state.resume {
        Some(resume) ->
          Resume(state.token, resume.id, resume.sequence) |> send_event(conn, _)
        None -> Identify(state.token) |> send_event(conn, _)
      }
      case handshake {
        Ok(Nil) -> logging.log(logging.Debug, "Gateway resume/identify sent")
        Error(e) ->
          logging.log(
            logging.Error,
            "Gateway resume/identify failed:\n" <> string.inspect(e),
          )
      }
      // Begin heartbeats
      process.spawn(fn() {
        start_pneumatic_heart(state.self, heartbeat_interval)
      })
      // Ok, so it isn't actually *ready* but it is closed enough
      stratus.continue(GatewayState(..state, ready: True))
    }
    // Record acknowledge
    Ok(HeartbeatAck) -> {
      logging.log(logging.Debug, "Heartbeat acknowledged")
      GatewayState(..state, heartbeat_acknowledged: True)
      |> stratus.continue
    }

    Error(JsonParse(e)) -> {
      logging.log(
        logging.Error,
        "Unable to parse message:\n" <> string.inspect(e),
      )
      stratus.continue(state)
    }
  }
}

/// Transform incoming JSON into a InboundEvent
/// 
/// [Opcode list](https://discord.com/developers/docs/topics/opcodes-and-status-codes#gateway)
fn parse_text_message(msg: String) -> Result(InboundEvent, Error) {
  let decoder = {
    use opcode <- decode.field("op", decode.int)

    case opcode {
      0 -> {
        use data <- decode.field("d", decode.dynamic)
        use name <- decode.field("t", decode.string)
        use sequence <- decode.field("s", decode.int)
        Dispatch(data:, sequence:, name:) |> decode.success
      }
      1 -> HeartbeatRequest |> decode.success
      7 -> Reconnect |> decode.success
      9 -> {
        use resume <- decode.field("d", decode.bool)
        InvalidSession(resume) |> decode.success
      }
      10 -> {
        use interval <- decode.subfield(["d", "heartbeat_interval"], decode.int)
        Hello(interval) |> decode.success
      }
      11 -> HeartbeatAck |> decode.success
      // Introduce error type or return a result instead?
      oc ->
        decode.failure(
          HeartbeatRequest,
          "Unknown opcode: " <> int.to_string(oc),
        )
    }
  }

  json.parse(msg, decoder) |> result.map_error(JsonParse)
}

fn handle_dispatch(
  data: Dynamic,
  name: String,
  watcher: Subject(watcher.Message),
  interaction_handler: fn(InteractionEvent) -> Nil,
) -> Nil {
  case name {
    "READY" -> {
      let decoder = {
        use url <- decode.field("resume_gateway_url", decode.string)
        use id <- decode.field("session_id", decode.string)
        #(url, id) |> decode.success
      }
      case decode.run(data, decoder) {
        Ok(#(url, id)) ->
          process.send(watcher, watcher.UpdateFromReady(url, id))
        Error(e) ->
          logging.log(
            logging.Warning,
            "Unable to decode READY data:\n" <> string.inspect(e),
          )
      }
      logging.log(logging.Info, "Gateway ready")
    }
    "RESUMED" -> logging.log(logging.Info, "Gateway resumed")
    // This should basically never happen given we have very few reasons to send requests
    "RATE_LIMITED" -> logging.log(logging.Warning, "Rate limit reached")
    "INTERACTION_CREATE" -> {
      // Discord requires a response within 3 seconds
      process_independently(2500, fn() {
        case interactions.parse_event(data) {
          Ok(i) -> interaction_handler(i)
          Error(e) ->
            logging.log(
              logging.Error,
              "Unable to parse interaction:\n" <> string.inspect(e),
            )
        }
      })
      Nil
    }
    _ -> logging.log(logging.Debug, "Ignoring dispatch event " <> name)
  }
}

// TODO: Cache sequence numbers somewhere so we ensure we don't handle them twice if we get them a second time

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
fn process_independently(timeout: Int, handler: fn() -> Nil) -> Pid {
  use <- process.spawn_unlinked
  use <- timing.timed("Interaction worker")

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
            "Interaction worker"
              <> string.inspect(child)
              <> "failed with reason "
              <> string.inspect(reason),
          )
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
        "Interaction worker " <> string.inspect(child) <> " timed out",
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

  logging.log(
    logging.Debug,
    "Interaction worker " <> string.inspect(child) <> "exited",
  )
}

type OutboundEvent {
  Heartbeat(sequence: Option(Int))
  Identify(token: String)
  Resume(token: String, session_id: String, sequence: Int)
}

type OutboundError {
  Socket(SocketReason)
}

/// Construct a message from opcode and data then send it to the server
fn raw_send_event(
  conn: Connection,
  opcode: Int,
  data: Json,
) -> Result(Nil, OutboundError) {
  json.object([#("op", json.int(opcode)), #("d", data)])
  |> json.to_string
  |> stratus.send_text_message(conn, _)
  |> result.map_error(Socket)
}

/// Send an OutboundEvent to the server
fn send_event(
  conn: Connection,
  event: OutboundEvent,
) -> Result(Nil, OutboundError) {
  case event {
    Heartbeat(seq) -> raw_send_event(conn, 1, json.nullable(seq, json.int))
    Identify(token) -> {
      // Ok, so our OS isn't gleam but it's a decent approximation that
      // doesn't involve trying to identify the actual OS
      let properties =
        json.object([
          #("os", json.string("gleam")),
          #("browser", json.string("space-game")),
          #("device", json.string("space-game")),
        ])
      // TODO: Set custom activity
      let presence =
        json.object([
          #("since", json.null()),
          #("activities", json.object([])),
          #("status", json.string("online")),
          #("afk", json.bool(False)),
        ])
      json.object([
        #("token", json.string(token)),
        #("properties", properties),
        // TODO: Look into compression
        #("compress", json.bool(False)),
        #("presence", presence),
        #("intents", json.int(0)),
      ])
      |> raw_send_event(conn, 2, _)
    }
    Resume(token, id, sequence) ->
      json.object([
        #("token", json.string(token)),
        #("session_id", json.string(id)),
        #("seq", json.int(sequence)),
      ])
      |> raw_send_event(conn, 6, _)
  }
}

/// Send heartbeat to server
/// 
/// This should only be called from inside the actor loop
fn beat_heart(
  state: GatewayState,
  conn: Connection,
) -> Next(GatewayState, GatewayAction) {
  case state.heartbeat_acknowledged {
    True -> {
      let state = GatewayState(..state, heartbeat_acknowledged: False)
      case send_event(conn, Heartbeat(state.sequence)) {
        Ok(Nil) -> {
          logging.log(logging.Debug, "Sent heartbeat")
          stratus.continue(state)
        }
        Error(e) -> {
          logging.log(
            logging.Warning,
            "Unable to send heartbeat:\n" <> string.inspect(e),
          )
          // We don't bother retrying, if the heartbeat fails then Discord
          // can just kill the session
          stratus.continue(state)
        }
      }
    }
    // if we haven't been acknowledged we are supposed to reconnect
    False -> {
      logging.log(logging.Warning, "Heartbeat not acknowledged, reconnecting")
      reconnect_and_resume(conn)
    }
  }
}

/// Send heartbeats every interval, with jitter applied to the first instance
fn start_pneumatic_heart(gateway: Subject(GatewayAction), interval: Int) -> Nil {
  logging.log(
    logging.Debug,
    "Heart started with interval " <> int.to_string(interval) <> "ms",
  )

  // Apply some jitter to the first sleep
  int.to_float(interval) *. float.random()
  |> float.truncate()
  |> int.max(1)
  |> process.sleep

  // Discord advises not to send heartbeats any faster than necessary
  // They allow for network latency
  // But we may get our heartbeat request delayed as the actor processes
  // early messages.
  // So we queue it a smidge early
  let send_interval =
    int.to_float(interval) *. 0.98
    |> float.truncate()
    // any faster and we'll hit the rate limit for sure
    |> int.max(500)
  logging.log(
    logging.Debug,
    "Adjusting heartbeat interval to "
      <> int.to_string(send_interval)
      <> "ms to account for actor queue",
  )

  pneumatic_heart(gateway, send_interval)
}

/// Send heartbeat every interval
/// 
/// The first request is sent immediately.
/// Does not return.
fn pneumatic_heart(gateway: Subject(GatewayAction), interval: Int) -> Nil {
  process.send(gateway, SendHeartbeat)
  process.sleep(interval)
  pneumatic_heart(gateway, interval)
}

/// Reconnect to Discord and resume the session
/// 
/// This works by killing the actor and relying on the 
/// supervisor to replace it.
fn reconnect_and_resume(conn: Connection) {
  logging.log(logging.Debug, "Reconnect and resume triggered")
  // We can resume so long as the watcher has the correct state, so all we need
  // to do is close the connection and stop the client.
  // we just want a close code that isn't 1000 or 1001
  let _ =
    stratus.close_with_reason(conn, stratus.UnexpectedCondition(<<"resuming">>))
  stratus.stop()
}
