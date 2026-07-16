//// General functions for interacting with the database.
//// 
//// On program start prepare the database by calling `init_database`
//// then use `with_readonly_connection` and `with_writeable_connection`
//// as appropriate. These functions accept a function as their last argument
//// so they are conveniently used with the `use` syntax, e.g.
//// ```
//// use conn <- with_readonly_connection("database_file_name")
//// some_func_using(conn)
//// let whatever = some_other_function_using_conn(conn, "hello")
//// ```
//// This is equivalent to
//// ```
//// with_readonly_connection("database_file_name", fn(conn) {
////    some_func_using(conn)
////    let whatever = some_other_function_using_conn(conn, "hello")  
//// })
//// ```
//// 
//// The connection will be closed automatically at the end of the block.
//// This is similar to a python `with` statement but there are differences.
//// See https://tour.gleam.run/everything/#advanced-features-use for details
//// on this syntax.
//// 
//// Both connection wrappers are thin wrappers around `sqlight.with_connection`
//// that add additional safeguards missing from said function.
//// 
//// Create new tables by adding them to `run_database_init_sql`.
//// Define abstractions for reading/writing to the database and associated types
//// in files in this subdirectory. These functions should accept an sqlight connection
//// (so the caller uses `with_*_connection`) or accept a path string and call the
//// connection wrapper themselves.

import gleam/result
import gleam/string
import logging
import sqlight.{type Connection}

fn open_connection(path: String, mode: String) {
  sqlight.open("file:" <> path <> "?mode=" <> mode)
}

/// Connect to a database in the specified mode
fn with_connection(
  path: String,
  mode: String,
  callback: fn(Connection) -> a,
) -> Result(a, sqlight.Error) {
  use conn <- result.try(open_connection(path, mode))
  let response = callback(conn)
  use _ <- result.map(sqlight.close(conn))
  response
}

/// Connect with a read only connection
/// 
/// This optimises connecting by skipping applying pragma that only matter
/// on write. We can have more read connections than write connections so favour this
/// unles you actually need writing.
pub fn with_readonly_connection(
  path: String,
  callback: fn(Connection) -> a,
) -> Result(a, sqlight.Error) {
  with_connection(path, "ro", callback)
}

/// Connect with a read/write connection.
///
/// Will NOT create the database if it doesn't already exist.
/// 
/// This warns but does not fail if it cannot enable foreign keys
pub fn with_writable_connection(
  path: String,
  callback: fn(Connection) -> a,
) -> Result(a, sqlight.Error) {
  with_connection(path, "rw", fn(conn) {
    case
      sqlight.exec(
        "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA synchronous = NORMAL;",
        conn,
      )
    {
      Ok(_) -> Nil
      Error(e) ->
        logging.log(
          logging.Warning,
          "Unable to enable foreign keys: " <> string.inspect(e),
        )
    }
    callback(conn)
  })
}

/// Connect with a read/write connection.
///
/// Will NOT create the database if it doesn't already exist.
/// Errors if it cannot enable foreign keys.
pub fn open_writable_connection(
  path: String,
) -> Result(Connection, sqlight.Error) {
  use conn <- result.try(open_connection(path, "rw"))
  use _ <- result.map(sqlight.exec(
    "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA synchronous = NORMAL;",
    conn,
  ))
  conn
}

pub type TransactionError(e) {
  /// Transaction rolled back due to error in inner function
  TransactionRolledBack(e)
  /// Unable to begin transaction
  TransactionBeginError(sqlight.Error)
  /// Unable to commit transaction
  TransactionCommitError(sqlight.Error)
  /// Tried to roll back transaction but failed
  TransactionRollbackError(rollback: sqlight.Error, query: e)
}

/// Run a sequence of database operations as a single transaction.
///
/// If an error is returned the entire transaction is rolled back.
/// This function returns a nested result, where the outer layer is Ok iff
/// the change was committed or successfully rolled back and the inner layer
/// represents if the supplied transaction function succeeded.
pub fn as_transaction(
  conn: Connection,
  transaction: fn(Connection) -> Result(a, e),
) -> Result(a, TransactionError(e)) {
  case sqlight.exec("BEGIN IMMEDIATE", conn) {
    Ok(_) -> {
      case transaction(conn) {
        Ok(query_returning) ->
          case sqlight.exec("COMMIT", conn) {
            Ok(_) -> query_returning |> Ok
            Error(commit_error) ->
              commit_error |> TransactionCommitError |> Error
          }
        Error(query_error) ->
          case sqlight.exec("ROLLBACK", conn) {
            Ok(_) -> query_error |> TransactionRolledBack |> Error

            Error(rollback_error) ->
              rollback_error
              |> TransactionRollbackError(query: query_error)
              |> Error
          }
      }
    }
    Error(begin_error) -> begin_error |> TransactionBeginError |> Error
  }
}
