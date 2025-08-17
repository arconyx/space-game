import gleam/list

pub type NonEmptyList(a) {
  NonEmptyList(first: a, rest: List(a))
}

/// Return a new list containing elements of the first list after applying
/// the given function to each.
pub fn map(list: NonEmptyList(a), with fun: fn(a) -> b) -> NonEmptyList(b) {
  NonEmptyList(fun(list.first), list.map(list.rest, fun))
}

pub fn to_list(list: NonEmptyList(a)) -> List(a) {
  [list.first, ..list.rest]
}
