import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import space_game/database/connection
import space_game/utils/debug
import sqlight

const max_attempts = 3

pub type Message {
  /// Run a query, rolling back if it returns an error
  Write(query: fn(sqlight.Connection) -> Result(Nil, String))
}

type State {
  State(conn: sqlight.Connection, database_path: String)
}

pub fn create_writer(
  name: process.Name(Message),
  database_path: String,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    case connection.open_writable_connection(database_path) {
      Ok(conn) ->
        State(conn:, database_path:)
        |> actor.initialised()
        |> actor.returning(subject)
        |> Ok
      // TODO: Log errors more specifically
      Error(_) -> Error("Unable to open a database connection")
    }
  })
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start()
}

pub fn call_writer(
  writer: process.Subject(Message),
  query: fn(sqlight.Connection) -> Result(Nil, String),
) {
  process.send(writer, Write(query:))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case write_using_transaction(state, message.query, 0) {
    Ok(state) -> actor.continue(state)
    Error(#(state, e)) -> {
      logging.log(
        logging.Error,
        "Unable to write data due to error " <> string.inspect(e),
      )
      actor.continue(state)
    }
  }
}

/// Run a query in a transaction.
///
/// Transactions will retried if they fail outside of the query.
/// 
/// Returns state on all paths, because it may reopen the connection
/// if errors occur.
fn write_using_transaction(
  state: State,
  query: fn(sqlight.Connection) -> Result(Nil, String),
  attempt: Int,
) -> Result(State, #(State, connection.TransactionError(String))) {
  // Run transaction and return if it suceeds
  use error <- result.try_recover(
    connection.as_transaction(state.conn, query)
    |> result.replace(state),
  )

  // Log nature of error and recreate the connection if the transaction
  // is in an unknown state
  let state = case error {
    connection.TransactionRolledBack(inner_error) -> {
      logging.log(
        logging.Debug,
        "Transaction rolled back on attempt "
          <> int.to_string(attempt)
          <> " due to error "
          <> inner_error
          <> "\n. Transaction will not be reattempted.",
      )
      state
    }
    connection.TransactionBeginError(begin_error) -> {
      logging.log(
        logging.Error,
        "Unable to begin transaction "
          <> int.to_string(attempt)
          <> " due to error "
          <> string.inspect(begin_error),
      )
      reconnect(state)
    }
    connection.TransactionCommitError(commit_error) -> {
      logging.log(
        logging.Error,
        "Unable to commit transaction "
          <> int.to_string(attempt)
          <> " due to error "
          <> string.inspect(commit_error),
      )
      reconnect(state)
    }
    connection.TransactionRollbackError(rollback:, query:) -> {
      logging.log(
        logging.Error,
        "Unable to rollback transaction "
          <> int.to_string(attempt)
          <> " due to error "
          <> string.inspect(rollback)
          <> "\n Rollback triggered due to error inside transaction: "
          <> query
          <> "\n. Transaction will not be reattempted",
      )
      reconnect(state)
    }
  }

  // Abort if we've made too many attempts
  use <- bool.lazy_guard(attempt > max_attempts, fn() {
    logging.log(
      logging.Error,
      "Transaction failed more than "
        <> int.to_string(max_attempts)
        <> "times. No further attempts will be made.",
    )
    #(state, error) |> Error
  })

  case error {
    connection.TransactionRolledBack(_)
    | connection.TransactionRollbackError(..) -> Ok(state)
    _ -> {
      process.sleep(int.clamp(250 * attempt, min: 50, max: 5000))
      write_using_transaction(state, query, attempt + 1)
    }
  }
}

/// Close the existing connection and return a new one.
/// 
/// This function is intended for discarding connections that have
/// gotten into a bad state where recovery is impossible. It panics
/// if the new connection cannot be opened. This is permissable
/// because it is only called within a supervised process.
fn reconnect(state: State) -> State {
  let _ =
    sqlight.close(state.conn)
    |> debug.log_error(
      logging.Error,
      "Error when closing writable database connection",
      string.inspect,
    )
  case sqlight.open(state.database_path) {
    Ok(conn) -> {
      logging.log(logging.Debug, "Recreated writable database connection")
      State(..state, conn:)
    }
    Error(e) -> {
      logging.log(
        logging.Critical,
        "Unable to recreate a writable database connection: "
          <> string.inspect(e),
      )
      // Let the supervisor handle this
      panic as "Unable to recreate writable database connection"
    }
  }
}
