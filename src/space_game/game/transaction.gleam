import gleam/int
import gleam/result
import logging
import space_game/storage.{type Player}

/// Adds `|credit|` to account
pub fn add_funds(player: Player, credit: Int) -> Player {
  update_funds(player, int.absolute_value(credit))
}

/// Removes `|debit|` from account
pub fn remove_funds(player: Player, debit: Int) -> Player {
  update_funds(player, debit |> int.absolute_value() |> int.negate())
}

/// Adds `delta` funds to account. 
/// 
/// If negative, funds will be removed. Prefer `add_funds` and `remove_funds`
/// where possible to avoid issues with negative inputs.
/// TODO: Transaction history?
fn update_funds(player: Player, delta: Int) -> Player {
  storage.Player(..player, account_balance: player.account_balance + delta)
}

pub type AccountError(e) {
  InsufficentFunds(current_balance: Int)
  TransactionFailed(e)
}

/// Subtract the given cost from the player and then run the given transaction
/// with the updated player as input.
/// 
/// If the cost exceeds the player account balance this returns an error and
/// does not run the transaction.
pub fn with_cost(
  player: Player,
  cost: Int,
  transaction transaction: fn(Player) -> Result(a, e),
) -> Result(a, AccountError(e)) {
  logging.log(
    logging.Debug,
    "Performing financial transaction for "
      <> player.discord_id
      <> " with cost "
      <> int.to_string(cost),
  )

  case remove_funds(player, cost) {
    storage.Player(account_balance:, ..) if account_balance < 0 ->
      InsufficentFunds(account_balance) |> Error
    player -> transaction(player) |> result.map_error(TransactionFailed)
  }
}
