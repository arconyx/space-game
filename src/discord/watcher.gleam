//// The watcher controls the gate
////
//// We have certain mutable state we wish to preserve across instances
//// of the gateway process. This module hosts an actor whose only job
//// is to preserve and supply this state.
//// 
//// Immutable state, like the bot token, is not the responsibility of 
//// this module. Consider embedding it in a closure.

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Next, type StartError, type Started}
import gleam/result
import gleam/string
import logging

/// Internal state of the watcher
/// 
/// The url and id are the `resume_gateway_url` and `session_id'
/// passed in the ready event. The sequence number is stored both
/// here and in the gateway state, because it must be preserved across
/// gateways but the gateway must also regularly access it for heartbeats.
type State {
  State(url: Option(String), id: Option(String), sequence: Option(Int))
}

const empty = State(None, None, None)

/// State information required by resume event
///
/// The url and id are the `resume_gateway_url` and `session_id'
/// passed in the ready event. The sequence number is stored both
/// here and in the gateway state, because it must be preserved across
/// gateways but the gateway must also regularly access it for heartbeats.
pub type ResumeState {
  ResumeState(url: String, id: String, sequence: Int)
}

/// Messages used to send instructions to the watcher
/// 
/// UpdateFromReady: Set resume state from information in the READY event
/// UpdateSequence: Store latest sequence number
/// Get: Fetch the latest resume state
/// Clear: Reset state, preventing resumes
pub type Message {
  UpdateFromReady(resume_url: String, session_id: String)
  UpdateSequence(sequence: Int)
  Get(Subject(Option(ResumeState)))
  Clear
}

/// Handle messages received by the watcher actor
fn handle_message(state: State, msg: Message) -> Next(State, Message) {
  case msg {
    UpdateFromReady(url, id) ->
      State(..state, url: Some(url), id: Some(id)) |> actor.continue
    UpdateSequence(seq) -> State(..state, sequence: Some(seq)) |> actor.continue
    Get(client) -> {
      let resp = case state {
        State(Some(url), Some(id), Some(seq)) ->
          ResumeState(url, id, seq) |> Some
        _ -> None
      }
      process.send(client, resp)
      actor.continue(state)
    }
    Clear -> empty |> actor.continue
  }
}

/// Start the watcher actor
pub fn start_watcher(
  name: Name(Message),
) -> Result(Started(Subject(Message)), StartError) {
  actor.new(empty)
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start()
  |> result.map(fn(r) {
    logging.log(logging.Debug, "Started watcher")
    r
  })
  |> result.map_error(fn(e) {
    logging.log(
      logging.Error,
      "Unable to start watcher:\n" <> string.inspect(e),
    )
    e
  })
}
