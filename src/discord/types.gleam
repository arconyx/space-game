//// Types we've had to extract from their natural homes
//// to avoid circular deps.

/// The bot.
///
/// This is information commonly needed for http requests.
/// The token is sensitive so try not to leak it into logs.
pub type Bot {
  Bot(token: String, id: String)
}
