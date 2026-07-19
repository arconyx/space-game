import gleam/dict
import gleam/erlang/process
import space_game/database/write
import space_game/discord/api
import space_game/game/goods
import space_game/game/ship

/// The context holds immutable global state
/// such as precomputed values derived from environment variables.
pub type Context {
  Context(
    bot: api.Bot,
    db: String,
    goods: dict.Dict(String, goods.Goods),
    ship_refresh_actor: process.Subject(ship.Message),
    writer: process.Subject(write.Message),
  )
}
