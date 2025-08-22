import cake/adapter/sqlite
import cake/insert
import cake/select
import database
import gleam/dynamic/decode
import gleam/float
import sqlight.{type Connection}

pub const table = "waypoints"

/// A waypoint, as represented in the database
pub type Waypoint {
  Waypoint(id: Int, name: String, x: Float, y: Float)
}

/// A waypoint that hasn't been inserted into the database yet
type NewWaypoint {
  NewWaypoint(name: String, x: Float, y: Float)
}

/// Table has an integer primary key and a unique name.
/// The (x,y) pair must also be unique as no two waypoints
/// can share the same position.
pub fn create_waypoints_table(conn: Connection) -> Result(Nil, sqlight.Error) {
  database.create_table(
    conn,
    table,
    database.integer_primary_key,
    [
      database.Column(
        name: "name",
        datatype: database.Text,
        nullable: False,
        constraints: "UNIQUE CHECK(name != '')",
      ),
      database.simple_col("x", database.Real),
      database.simple_col("y", database.Real),
    ],
    "UNIQUE(x, y)",
  )
}

fn waypoint_to_sql(waypoint: NewWaypoint) -> insert.InsertRow {
  [
    waypoint.name |> insert.string,
    waypoint.x |> insert.float,
    waypoint.y |> insert.float,
  ]
  |> insert.row
}

/// expects [id, name, x, y]
fn sql_to_waypoint() -> decode.Decoder(Waypoint) {
  use id <- decode.field(0, decode.int)
  use name <- decode.field(1, decode.string)
  use x <- decode.field(2, decode.float)
  use y <- decode.field(3, decode.float)
  Waypoint(id:, name:, x:, y:) |> decode.success
}

fn insert_waypoints(
  conn: Connection,
  waypoints: List(NewWaypoint),
) -> Result(List(Waypoint), sqlight.Error) {
  waypoints
  |> insert.from_records(table, ["name", "x", "y"], _, waypoint_to_sql)
  |> insert.returning(["id", "name", "x", "y"])
  |> insert.to_query
  |> sqlite.run_write_query(sql_to_waypoint(), conn)
}

pub fn select_all_waypoints(
  conn: Connection,
) -> Result(List(Waypoint), sqlight.Error) {
  select.new()
  |> select.from_table(table)
  |> select.select_cols(["id", "name", "x", "y"])
  |> select.to_query()
  |> sqlite.run_read_query(sql_to_waypoint(), conn)
}

pub fn demo_waypoint(db: String) {
  let waypoints = [
    NewWaypoint("Point A", 0.1, 0.3),
    NewWaypoint("Point B", 0.2, 0.1),
  ]
  use conn <- database.with_writable_connection(db)
  insert_waypoints(conn, waypoints)
}

/// Calculates the magnitude of the distance vector between A and B
pub fn distance(a: Waypoint, b: Waypoint) -> Float {
  let dx = a.x -. b.x
  let dy = a.y -. b.y
  // errors on negative bases with fractional exponents
  // or on 0 base with negative exponents
  // we are doing neither, by construction
  let assert Ok(dist) = float.square_root(dx *. dx +. dy *. dy)
  dist
}
