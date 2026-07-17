import gleam/list
import gleam/result
import gleam/string
import sqlight.{type Connection}

/// Create the database and init it with inital config
/// 
/// This must be safe to call on an existing database.
pub fn init_database(
  path: String,
  initalizer fun: fn(Connection) -> Result(a, sqlight.Error),
) -> Result(a, sqlight.Error) {
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
  with fun: fn(Connection) -> Result(a, sqlight.Error),
) -> Result(a, sqlight.Error) {
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

pub fn string_primary_key(name: String) {
  { "CHECK(" <> name <> " != '')" }
  |> PrimaryKeyColumn(name:, datatype: Text, constraints: _)
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
) -> Result(Nil, sqlight.Error) {
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
