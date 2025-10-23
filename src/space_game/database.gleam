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

import gleam/list
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

/// Run a sequence of database operations as a single transaction.
///
/// If an error is returned the entire transaction is rolled back.
/// This function returns a nested result, where the outer layer is Ok iff
/// the change was commit/successfully rolled back and the inner layer
/// represents if the supplied transaction function succeeded.
pub fn as_transaction(
  conn: Connection,
  transaction: fn() -> Result(a, b),
) -> Result(Result(a, b), sqlight.Error) {
  case sqlight.exec("BEGIN", conn) {
    Ok(_) -> {
      logging.log(logging.Debug, "Database transaction started")
      case transaction() {
        Ok(v) ->
          case sqlight.exec("COMMIT", conn) {
            Ok(_) -> {
              logging.log(logging.Debug, "Database transaction succeeded")
              Ok(v) |> Ok
            }
            Error(ce) -> {
              logging.log(
                logging.Error,
                "Database transaction succeeded but commit failed",
              )
              Error(ce)
            }
          }
        Error(e) -> {
          logging.log(
            logging.Debug,
            "Database transaction failed, rolling back",
          )
          case sqlight.exec("ROLLBACK", conn) {
            Ok(_) -> {
              logging.log(logging.Debug, "Rollback succeeded")
              e |> Error |> Ok
            }
            Error(re) -> {
              logging.log(
                logging.Critical,
                "Rollback failed, database dirty!\nOriginal error was:\n"
                  <> string.inspect(e)
                  <> "\nRollback error was:\n"
                  <> string.inspect(re),
              )
              re |> Error
            }
          }
        }
      }
    }
    Error(e) -> {
      logging.log(logging.Error, "Unable to begin database transaction")
      Error(e)
    }
  }
}

/// Create the database and init it with inital config
/// 
/// This must be safe to call on an existing database.
pub fn init_database(
  path: String,
  initalizer fun: fn(Connection) -> Result(a, Error),
) -> Result(a, Error) {
  case sqlight.open("file:" <> path <> "?mode=rwc") {
    Error(e) -> Error(e)
    Ok(conn) ->
      case run_database_init_sql(conn, fun) {
        Error(e) -> Error(e)
        Ok(v) -> {
          use _ <- result.try(sqlight.close(conn))
          Ok(v)
        }
      }
  }
}

/// Helper method to group all sql run on database init
/// 
/// This is called by `init_database` so it must be idempotent
/// i.e. safe to run repeatedly on existing databases
/// 
/// Create new tables by adding lines to thing
fn run_database_init_sql(
  conn: Connection,
  with fun: fn(Connection) -> Result(a, Error),
) -> Result(a, Error) {
  use _ <- result.try(sqlight.exec("PRAGMA journal_mode=WAL;", conn))
  fun(conn)
}

/// Data types supported by SQLite
pub type ColumnType {
  Integer
  Real
  Text
  Blob
  Any
}

/// A column definition for use in table creation
pub type Column {
  Column(
    name: String,
    datatype: ColumnType,
    nullable: Bool,
    constraints: String,
  )
}

/// A helper to create a non-null column with no contraints
pub fn simple_col(name: String, datatype: ColumnType) {
  Column(name:, datatype:, nullable: False, constraints: "")
}

/// A column with the primary key constraint enforced
pub type PrimaryKeyColumn {
  PrimaryKeyColumn(name: String, datatype: ColumnType, constraints: String)
}

/// A standard integer primary key
pub const integer_primary_key = PrimaryKeyColumn("id", Integer, "")

fn column_to_sql(col: Column) -> String {
  let stype = case col.datatype {
    Integer -> "INTEGER"
    Real -> "REAL"
    Text -> "TEXT"
    Blob -> "BLOB"
    Any -> "ANY"
  }
  let constraints = case col.nullable {
    True -> col.constraints
    False -> "NOT NULL " <> col.constraints
  }
  string.join([col.name, stype, constraints], " ")
}

/// Wrapper for creating a table from a list of columns
///
/// We mandate the supply of an explicit primary key so we
/// can enforce sanity checks on it.
pub fn create_table(
  conn: Connection,
  name: String,
  primary_key: PrimaryKeyColumn,
  cols: List(Column),
  table_constraints: String,
) -> Result(Nil, Error) {
  {
    "CREATE TABLE IF NOT EXISTS "
    <> name
    <> "("
    <> {
      [
        Column(
          name: primary_key.name,
          datatype: primary_key.datatype,
          nullable: False,
          constraints: "PRIMARY KEY " <> primary_key.constraints,
        ),
        ..cols
      ]
      |> list.map(column_to_sql)
      |> string.join(", ")
      <> case table_constraints {
        "" -> ""
        consts -> ", " <> consts
      }
    }
    <> ") STRICT "
  }
  |> sqlight.exec(conn)
}
