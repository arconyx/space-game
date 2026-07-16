//// A NonEmptyList type, and associated methods
//// for when you really don't want to deal with the empty case.
////
//// There is a perfectly good package for this on Hex, but rolling
//// our own was a minimum of work and avoids another dependency.

import gleam/list

/// A list that must have at least one item
pub type NonEmptyList(a) {
  NonEmptyList(first: a, rest: List(a))
}

/// Return a new list containing elements of the first list after applying
/// the given function to each.
pub fn map(list: NonEmptyList(a), with fun: fn(a) -> b) -> NonEmptyList(b) {
  NonEmptyList(fun(list.first), list.map(list.rest, fun))
}

/// Transform a NonEmptyList into a regular list.
///
/// We don't have a function to go the other way because
/// it may fail and you might as well use a regular list at
/// that point. Users can trivially construct a NonEmptyList if
/// they can demonstrate their list is in fact non-empty.
pub fn to_list(list: NonEmptyList(a)) -> List(a) {
  [list.first, ..list.rest]
}
