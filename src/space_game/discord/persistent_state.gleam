import booklet
import gleam/option.{type Option, None, Some}

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
}

pub fn init(initial_gateway_url: String) -> PersistentState {
  Initial(initial_gateway_url:, sequence_number: None)
  |> booklet.new()
  |> PersistentState
}

pub fn get_gateway_url(state: PersistentState) -> String {
  case booklet.get(state.booklet) {
    Initial(initial_gateway_url:, ..) -> initial_gateway_url
    Resumable(resume_gateway_url:, ..) -> resume_gateway_url
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
  }
  |> booklet.set(state.booklet, _)
}

pub fn clear_resume_state(state: PersistentState) -> Nil {
  booklet.get(state.booklet).initial_gateway_url
  |> Initial(None)
  |> booklet.set(state.booklet, _)
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
  }
  |> booklet.set(state.booklet, _)
}
