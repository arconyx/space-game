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
import sqlight.{type Connection, type Error}

/// Connect to a database in the specified mode
/// 
/// This will panic if the connection cannot be opened or closed.
fn with_connection(
  path: String,
  mode: String,
  callback: fn(Connection) -> a,
) -> a {
  sqlight.with_connection("file:" <> path <> "?mode=" <> mode, callback)
}

/// Connect with a read only connection
/// 
/// This optimises connecting by skipping applying pragma that only matter
/// on write. We can have more read connections than write connections so favour this
/// unles you actually need writing.
/// 
/// This will panic if the connection cannot be opened or closed.
pub fn with_readonly_connection(
  path: String,
  callback: fn(Connection) -> a,
) -> a {
  with_connection(path, "ro", callback)
}

/// Connect with a read/write connection.
///
/// Will NOT create the database if it doesn't already exist.
/// This will panic if the connection cannot be opened or closed.
pub fn with_writable_connection(
  path: String,
  callback: fn(Connection) -> a,
) -> a {
  with_connection(path, "rwc", fn(conn) {
    case sqlight.exec("PRAGMA foreign_keys = ON;", conn) {
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

/// Create the database and init it with inital config
/// 
/// This should be safe to call on an existing database.
pub fn init_database(path: String) -> Result(Nil, Error) {
  case sqlight.open("file:" <> path <> "?mode=rwc") {
    Error(e) -> Error(e)
    Ok(conn) ->
      case run_database_init_sql(conn) {
        Error(e) -> Error(e)
        Ok(Nil) -> sqlight.close(conn)
      }
  }
}

/// Helper method to group all sql run on database init
/// 
/// This is called by `init_database` so it must be idempotent
/// i.e. safe to run repeatedly on existing databases
/// 
/// Create new tables by adding lines to thing
fn run_database_init_sql(conn: Connection) -> Result(Nil, Error) {
  use _ <- result.try(sqlight.exec("PRAGMA journal_mode=WAL;", conn))
  // Create a table
  // use _ <- result.try(sqlight.exec("some sql to create the table", conn))
  Nil |> Ok
}
