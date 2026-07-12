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

import gleam/bit_array
import gleam/dynamic/decode.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import space_game/discord/api
import space_game/discord/interactions.{type InteractionEvent}
import space_game/discord/persistent_state.{type PersistentState}
import stratus.{
  type Connection, type InternalMessage, type Message, type Next,
  type SocketReason,
}

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
type GatewayState {
  GatewayState(
    token: String,
    persistent_state: PersistentState,
    self: Subject(GatewayAction),
    // we need this for heartbeats as well as resuming
    sequence: Option(Int),
    heartbeat_interval_ms: Option(Int),
    last_heartbeat_acknowledged: Bool,
    next_heartbeat: Option(process.Timer),
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
    persistent_state: PersistentState,
    handler: fn(InteractionEvent) -> Nil,
  )
}

/// Get websockets address used to connect to Discord
/// 
/// Discord supplies the address in the response to a GET
pub fn get_websocket_address(token: String) -> Result(String, api.Error) {
  api.request(token, http.Get, "/gateway/bot", None)
  |> api.send_and_decode(decode.at(["url"], decode.string))
}

/// Open a connection to Discord using their Gateway protocol
/// over websockets
/// 
/// This function will panic if the watcher is unavailable
pub fn open(gateway: GatewayBuilder) {
  // Get the url Discord wants us to connect to, using the resume
  // address if set

  // TODO: Do we actually send the resume event when resuming?

  // Gleam chokes on 'ws' and 'wss' prefixes
  // We deliberately upgrade ws/http to wss/https because eww unencrypted connection
  let url =
    persistent_state.get_gateway_url(gateway.persistent_state)
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
    GatewayState(
      gateway.token,
      gateway.persistent_state,
      self,
      None,
      None,
      True,
      None,
      False,
    )
    |> stratus.initialised()
    |> stratus.selecting(process.new_selector() |> process.select(self))
    |> Ok
  })
  |> stratus.on_message(fn(state, msg, conn) {
    handle_messages(state, msg, conn, gateway.handler)
  })
  |> stratus.on_close(on_close)
  |> stratus.start()
  |> result.map(fn(r) {
    logging.log(logging.Debug, "Gateway started")
    r
  })
}

/// Handle when the connection is closed without us requesting it
/// 
/// This function will panic when the close code suggests reconnection should
/// be avoided.
fn on_close(state: GatewayState, reason: stratus.CloseReason) {
  case reason {
    // We are allowed to resume when the gateway is closed without a code
    stratus.NotProvided ->
      logging.log(logging.Info, "Gateway closed by Discord without reason")
    stratus.Normal(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1000 normal: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.GoingAway(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1001 going away: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.ProtocolError(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Warning,
        "Gateway closed with code 1002 protocol error: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.UnexpectedDataType(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1003 unexpected data type: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.InconsistentDataType(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1007 inconsistent data type"
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.PolicyViolation(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1008 policy violation: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.MessageTooBig(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1009 message too big: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.MissingExtensions(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with status 1010 missing extensions: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.UnexpectedCondition(body:) -> {
      persistent_state.clear_resume_state(state.persistent_state)
      logging.log(
        logging.Info,
        "Gateway closed with code 1011 unexpected condition: "
          <> safe_bit_array_to_string(body),
      )
    }
    stratus.Custom(reason) ->
      case stratus.get_custom_code(reason) {
        4000 ->
          logging.log(logging.Warning, "Discord closed gateway: unknown error")
        4001 ->
          logging.log(logging.Warning, "Discord closed gateway: invalid opcode")
        4002 ->
          logging.log(logging.Warning, "Discord closed gateway: decode error")
        4003 ->
          logging.log(
            logging.Warning,
            "Discord closed gateway: not authenticated",
          )
        4004 -> {
          persistent_state.clear_resume_state(state.persistent_state)
          logging.log(
            logging.Warning,
            "Discord closed gateway: authentication failed",
          )
        }
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
          logging.log(logging.Warning, "Discord closed gateway: rate limited")
        4009 ->
          logging.log(logging.Warning, "Discord closed gateway: timed out")
        4010 -> {
          logging.log(
            logging.Warning,
            "Discord closed gateway: invalid shard specified",
          )
          // TODO: Does a panic really shutdown properly?
          // Make this a significant transient child instead?
          // Will stratus intefer with the shutdowns?
          panic as "Invalid shard specified"
        }
        4011 -> {
          persistent_state.clear_resume_state(state.persistent_state)
          logging.log(
            logging.Error,
            "Discord closed gateway: sharding required",
          )
          panic as "Sharding required"
        }
        4012 -> {
          persistent_state.clear_resume_state(state.persistent_state)
          logging.log(
            logging.Error,
            "Discord closed gateway: invalid api version",
          )
          panic as "Invalid API version"
        }
        4013 -> {
          persistent_state.clear_resume_state(state.persistent_state)
          logging.log(logging.Error, "Discord closed gateway: invalid intent")
          panic as "Invalid intent"
        }
        4014 -> {
          persistent_state.clear_resume_state(state.persistent_state)
          logging.log(
            logging.Error,
            "Discord closed gateway: disallowed intent",
          )
          panic as "Disallowed intent"
        }
        code -> {
          logging.log(
            logging.Warning,
            "Discord closed gateway: " <> int.to_string(code),
          )
        }
      }
  }
}

fn safe_bit_array_to_string(array: BitArray) -> String {
  bit_array.to_string(array)
  |> result.unwrap("Unable to decode bit array associated with error")
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
      case stratus.close(conn, stratus.Normal(<<"bot shutdown">>)) {
        Error(_) ->
          logging.log(
            logging.Warning,
            "Error when sending shutdown event to Discord",
          )
        _ -> Nil
      }
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
      persistent_state.update_sequence(state.persistent_state, sequence)
      handle_dispatch(data, name, state.persistent_state, interaction_handler)
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
          let _ = stratus.close(conn, stratus.Normal(<<"invalid session">>))
          persistent_state.clear_resume_state(state.persistent_state)
          stratus.stop_abnormal("invalid session")
        }
      }
    // Respond with identify
    Ok(Hello(heartbeat_interval)) -> {
      logging.log(logging.Debug, "Got hello from Discord")
      // If we're resuming send a resume instead of an identify
      let handshake = case
        persistent_state.get_resume_state(state.persistent_state)
      {
        Some(resume) ->
          Resume(state.token, resume.session_id, resume.sequence_number)
          |> send_event(conn, _)
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

      logging.log(
        logging.Debug,
        "Heart started with interval "
          <> int.to_string(heartbeat_interval)
          <> "ms",
      )

      let state =
        GatewayState(..state, heartbeat_interval_ms: Some(heartbeat_interval))

      // Apply some jitter to the first sleep as instructed by Discord
      int.to_float(heartbeat_interval) *. float.random()
      |> float.truncate()
      |> int.max(1)
      |> process.send_after(state.self, _, SendHeartbeat)

      // Ok, so it isn't actually *ready* but it is close enough
      stratus.continue(GatewayState(..state, ready: True))
    }
    // Record heartbeat acknowledgements
    Ok(HeartbeatAck) -> {
      logging.log(logging.Debug, "Heartbeat acknowledged")
      GatewayState(..state, last_heartbeat_acknowledged: True)
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

/// Handle messages with the 0-DISPATCH opcode
fn handle_dispatch(
  data: Dynamic,
  name: String,
  state: PersistentState,
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
        Ok(#(url, id)) -> persistent_state.set_resume_state(state, url, id)
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
      interactions.process_independently(
        2500,
        "Interaction worker",
        fn() { Nil },
        fn() {
          case interactions.parse_event(data) {
            Ok(i) -> interaction_handler(i)
            Error(e) ->
              logging.log(
                logging.Error,
                "Unable to parse interaction:\n"
                  <> interactions.parse_error_to_string(e),
              )
          }
        },
      )
      Nil
    }
    _ -> logging.log(logging.Debug, "Ignoring dispatch event " <> name)
  }
}

// TODO: Cache sequence numbers somewhere so we ensure we don't handle them twice if we get them a second time

/// Events we send to the server over the gateway
///
/// Interaction responses instead go over the http API
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
fn beat_heart(
  state: GatewayState,
  conn: Connection,
) -> Next(GatewayState, GatewayAction) {
  case state.last_heartbeat_acknowledged {
    // If we haven't been acknowledged we are supposed to reconnect
    False -> {
      logging.log(logging.Warning, "Heartbeat not acknowledged, reconnecting")
      reconnect_and_resume(conn)
    }
    True -> {
      // Send the next heartbeat
      case send_event(conn, Heartbeat(state.sequence)) {
        Ok(Nil) -> {
          logging.log(logging.Debug, "Sent heartbeat")
          GatewayState(..state, last_heartbeat_acknowledged: False)
        }
        Error(e) -> {
          // We don't bother retrying, if the heartbeat fails then Discord
          // can just kill the session
          logging.log(
            logging.Warning,
            "Unable to send heartbeat:\n" <> string.inspect(e),
          )
          state
        }
      }
      // Reset the timer
      case state.heartbeat_interval_ms {
        Some(interval_ms) -> {
          // We explicitly clear the timer because this function can be
          // invoked early when Discord requests an immediate heartbeat
          // The docs are unclear as to whether this should reset the interval.
          // We will assume so unless we see an elevated level of disconnects.
          let _ = option.map(state.next_heartbeat, process.cancel_timer)
          GatewayState(
            ..state,
            next_heartbeat: process.send_after(
                state.self,
                interval_ms,
                SendHeartbeat,
              )
              |> Some,
          )
        }
        None -> state
      }
      |> stratus.continue()
    }
  }
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
  let _ = stratus.close_custom(conn, 1012, <<"reconnecting and resuming">>)
  stratus.stop()
}
