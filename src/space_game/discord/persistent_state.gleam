import booklet
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import logging

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

pub fn init(initial_gateway_url: String) -> PersistentState {
  Initial(initial_gateway_url:, sequence_number: None)
  |> booklet.new()
  |> PersistentState
}

pub fn get_gateway_url(state: PersistentState) -> Result(String, String) {
  case booklet.get(state.booklet) {
    Initial(initial_gateway_url:, ..) -> Ok(initial_gateway_url)
    Resumable(resume_gateway_url:, ..) -> Ok(resume_gateway_url)
    DoNotResume(reason) -> Error(reason)
  }
}

pub type ResumeState {
  ResumeState(
    resume_gateway_url: String,
    session_id: String,
    sequence_number: Int,
  )
}

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

pub fn clear_resume_state(state: PersistentState) -> Nil {
  case booklet.get(state.booklet) {
    Initial(initial_gateway_url:, ..) | Resumable(initial_gateway_url:, ..) ->
      Initial(initial_gateway_url:, sequence_number: None)
      |> booklet.set(state.booklet, _)
    DoNotResume(_) -> Nil
  }
}

pub fn update_sequence(
  state: PersistentState,
  new_sequence_number: Int,
) -> Nil {
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
/// 
/// This is intended for situations where Discord sends a disconnect and
/// does not permit reconnecting, e.g. when we provide invalid auth values.
/// 
/// Expected to only be called by the gateway actor.
pub fn stop_forever(state: PersistentState, reason: String) -> Nil {
  logging.log(logging.Debug, "Gateway Do-Not-Restart triggered")
  booklet.set(state.booklet, DoNotResume(reason))
  process.send_abnormal_exit(process.self(), reason)
}
