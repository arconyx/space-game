-module(space_game_ffi).

-export([now/0]).

now() ->
    erlang:monotonic_time(millisecond).

