import cake/adapter/sqlite
import cake/insert
import cake/select
import database
import gleam/dynamic/decode
import sqlight.{type Connection}

const table = "waypoints"

/// A waypoint, as represented in the database
pub type Waypoint {
  Waypoint(id: Int, name: String, x: Float, y: Float)
}

/// A waypoint that hasn't been inserted into the database yet
pub type NewWaypoint {
  NewWaypoint(name: String, x: Float, y: Float)
}

/// Table has an integer primary key and a unique name.
/// The (x,y) pair must also be unique as no two waypoints
/// can share the same position.
pub fn create_waypoints_table(conn: Connection) -> Result(Nil, sqlight.Error) {
  database.create_table(
    conn,
    "waypoints",
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

fn sql_to_waypoint() -> decode.Decoder(Waypoint) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use x <- decode.field("x", decode.float)
  use y <- decode.field("y", decode.float)
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
