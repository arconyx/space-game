import gleam/dict.{type Dict}
import gleam/list

pub type Goods {
  Goods(name: String, std_unit_price: Int)
}

/// We can't use functions for constants so dicts are right out
pub const all_goods = [
  Goods("Spice", 5000),
  Goods("Paperclips", 1000),
  Goods("Antimatter", 10_000),
  Goods("Poles (3.048m)", 1000),
]

/// Dict of String
pub fn goods_dict(goods_list: List(Goods)) -> Dict(String, Goods) {
  goods_list
  |> list.map(fn(g) { #(g.name, g) })
  |> dict.from_list()
}
