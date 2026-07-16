//// The websockets connection to the Discord gateway must cache some data
//// across restarts. This module provides methods to store and access these
//// values in an ETS table, using the `PersistentState` object to hold a
//// reference to their location.
//// 
//// These functions are only used by the `space_game/discord/gateway` module
//// but live here so that type opacity can be used to inforce invariants and
//// trigger side-effects with no possiblity of bypass.

import booklet
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import logging

/// Holds a reference to the persistent state in an ETS table.
pub opaque type PersistentState {
  PersistentState(booklet: booklet.Booklet(State))
}

/// Persistent gateway state
/// 
/// The url and id are the `resume_gateway_url` and `session_id'
/// passed in the ready event. The sequence number is stored both
/// here and in the gateway state, because it must be preserved across
/// gateways but the gateway must also regularly access it for heartbeats.
type State {
  Initial(initial_gateway_url: String, sequence_number: Option(Int))
  Resumable(
    initial_gateway_url: String,
    sequence_number: Option(Int),
    resume_gateway_url: String,
    session_id: String,
  )
  DoNotResume(reason: String)
}

/// Create a new state object.
pub fn init(initial_gateway_url: String) -> PersistentState {
  Initial(initial_gateway_url:, sequence_number: None)
  |> booklet.new()
  |> PersistentState
}

/// Get the gateway url. This returns the resume gateway if present, else the
/// initial gateway.
pub fn get_gateway_url(state: PersistentState) -> Result(String, String) {
  case booklet.get(state.booklet) {
    Initial(initial_gateway_url:, ..) -> Ok(initial_gateway_url)
    Resumable(resume_gateway_url:, ..) -> Ok(resume_gateway_url)
    DoNotResume(reason) -> Error(reason)
  }
}

/// Holds the information required to resume a session.
/// 
/// This gets a dedicated object to avoid mixing up the strings.
pub type ResumeState {
  ResumeState(
    resume_gateway_url: String,
    session_id: String,
    sequence_number: Int,
  )
}

/// Fetch all the information required to resume a session.
/// 
/// If this returns some value then resumption should be attempted. Else perform
/// a standard reconnect.
pub fn get_resume_state(state: PersistentState) -> Option(ResumeState) {
  case booklet.get(state.booklet) {
    Resumable(
      sequence_number: Some(sequence_number),
      resume_gateway_url:,
      session_id:,
      ..,
    ) -> ResumeState(resume_gateway_url:, session_id:, sequence_number:) |> Some
    _ -> None
  }
}

/// Store the session resumption configuration provided by Discord in the READY
/// event.
pub fn set_resume_state(
  state: PersistentState,
  resume_gateway_url: String,
  session_id: String,
) -> Nil {
  case booklet.get(state.booklet) {
    Initial(initial_gateway_url:, sequence_number:) ->
      Resumable(
        initial_gateway_url:,
        sequence_number:,
        resume_gateway_url:,
        session_id:,
      )
    Resumable(..) as current ->
      Resumable(..current, resume_gateway_url:, session_id:)
    DoNotResume(..) as current -> current
  }
  |> booklet.set(state.booklet, _)
}

/// Clear all persistent resume state.
/// 
/// Future callers to `get_resume_state` will be returned `None`, signaling to
/// begin a fresh session instead of resuming. As such this function should be
/// called when the gateway is disconnected in such a manner that Discord
/// prohibits reconnection.
pub fn clear_resume_state(state: PersistentState) -> Nil {
  case booklet.get(state.booklet) {
    Initial(initial_gateway_url:, ..) | Resumable(initial_gateway_url:, ..) ->
      Initial(initial_gateway_url:, sequence_number: None)
      |> booklet.set(state.booklet, _)
    DoNotResume(_) -> Nil
  }
}

/// Get the last sequence number seen in a Dispatch message.
/// 
/// This is always the latest value seen, not the largest.
pub fn get_sequence(state: PersistentState) -> Option(Int) {
  case booklet.get(state.booklet) {
    Initial(sequence_number:, ..) | Resumable(sequence_number:, ..) ->
      sequence_number
    DoNotResume(_) -> None
  }
}

/// Store the provided sequence value, overwriting the previous value.
pub fn set_sequence(state: PersistentState, new_sequence_number: Int) -> Nil {
  case booklet.get(state.booklet) {
    Initial(..) as current ->
      Initial(..current, sequence_number: Some(new_sequence_number))
    Resumable(..) as current ->
      Resumable(..current, sequence_number: Some(new_sequence_number))
    DoNotResume(..) as current -> current
  }
  |> booklet.set(state.booklet, _)
}

/// Stop calling process and set flag in state booklet to prevent restarts.
/// The event is logged.
/// 
/// This is intended for situations where Discord sends a disconnect and
/// does not permit reconnecting, e.g. when we provide invalid auth values.
/// 
/// Expected to only be called by the gateway actor.
pub fn stop_forever(state: PersistentState, reason: String) -> Nil {
  logging.log(
    logging.Debug,
    "Gateway Do-Not-Restart set. The calling process will exit and restarts will be blocked.",
  )
  booklet.set(state.booklet, DoNotResume(reason))
  process.send_abnormal_exit(process.self(), reason)
}
