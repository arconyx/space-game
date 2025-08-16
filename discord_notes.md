Communication with Discord is done through a gateway, which is a websockets connection.

# Gateway Events
Gateway events have the structure
```json
{
  "op": 0, # integer?, opcode
  "d": {}, # json?, data
  "s": 42, # integer?, sequence number
  "t": "GATEWAY_EVENT_NAME" # string?, name
}
```
- [Opcodes](https://discord.com/developers/docs/topics/opcodes-and-status-codes#gateway-gateway-opcodes) indicate the payload type.
- The data is an arbitary json structure holding information for the event. It varies between different events.
- The sequence number is used for resuming sessions and heartbeats. It is null when `op != 0`. We must always be aware of the latest non-null sequence number received.

Opcodes (in opcode-name format) are:
- 0-DISPATCH (rec)
- 1-HEARTBEAT (send/rec)
- 2-IDENTIFY (send)
- 3-PRESENCE-UPDATE (send)
- ~~4-VOICE-STATE-UPDATE (send)~~
- 6-RESUME (send)
- 7-RECONNECT (rec)
- ~~8-REQUEST-GUILD-MEMBERS (send)~~
- 9-INVALID-SESSION (rec)
- 10-HELLO (rec)
- 11-HEARTBEAT-ACK (rec)
- ~~31-SOUNDBOARD-REQUEST (send)~~
with the ones we aren't interested in crossed out.

# Send Events
These are the events we can send
- Identify: introduce ourselves to the gateway
- Resume: pick up a dropped gateway connection
- Heartbeat: assure the other side of the connection that we're still alive
- ~~Request guild members~~
- ~~Request soundboard sounds~~
- ~~Update voice state: join/leave vc~~
- Update presence: set online/offline, etc. Will this work automatically if we neglect it? Ah, we can specify it as part of Identify and it'll be set to offline when we disconnect.
I've crossed out the events we don't care about.

Events must be serialised in plain-text JSON or binary [ETF](https://erlang.org/doc/apps/erts/erl_ext_dist.html) (user picks). There is optional compression.
Events must not exceed 4096 bytes. If they do, Discord will close the connection with 4002 error code.

## Heartbeat
Send heartbeats every `heartbeat_interval` ms (provided by server) after 10-HELLO payload received. Include latest sequence number, or null if we haven't received one yet.

The first heartbeat must be send `jitter*heartbeat_interval` after receiving 10-HELLO.
Subsequent heartbeats should be sent every `heartbeat_interval`. If we ever do not receive
a 11-HEARTBEAT-ACK we should close the connection (with any close code but 1000 or 1001) and reconnect. We may also receive 1-HEARTBEAT
events, which we should respond to by sending a heartbeat immediately.

This should have a dedicated handler

# Received Events
Including only the ones we care about
- Hello: defines heartbeat interval
- Ready: contains initial state. We'll need a way to store some of this
- Resumed: response to resume
- Reconnect: instruction from server
- Rate limited
- Invalid session
- Interaction create: user triggered interaction, like /slash commands

We control what events we can recieve by passing intents with our identify request. This is a bit flag.

Most events are 0-DISPATCH.

# Connection Flow
1. Get the WSS URL with a HTTP GET. They ask us to cache this.
2. Open websockets connection to that url
3. Discord sends hello event containing `heartbeat_interval`. We are now responsible for keeping the heart pumping.
4. We send an 2-IDENTIFY event
5. Discord sends a 0-READY event

The connection may be dropped at any time. We should resume or reconnect, depending on the reason the connection was dropped.

# Rate Limits
120 gateway events / connection / minute

# Interactions
Lets only worry about slash commands, also known as CHAT_INPUT.
- command names and command option names must match the following regex `^[-_'\p{L}\p{N}\p{sc=Deva}\p{sc=Thai}]{1,32}$` with the unicode flag set. If there is a lowercase variant of any letters used, you must use those. 
- Commands are registered with an HTTP request
- There's an option to overwrite the command list with a list of new commands. That seems like a good option.

# Close Codes
Returned when a websockets connection is closed.
We should handle all the ones listed by [Discord](https://discord.com/developers/docs/topics/opcodes-and-status-codes#gateway-gateway-close-event-codes). Some require reconnecting,
others don't.

We can return code 1000 or 1002 to alert Discord to a connection closure if we do not intend to reconnect (but it will also time out after a few minutes).

# Design Notes
- Spawn a dedicated process to send heartbeats every N ms. It can just sleep between sends. Supervise it because we don't want it to die.
- Use an actor with a push/query model to store sequence number.
- Create the bot with a builder then return a live instance from the start method with metadata from the ready method.

Require commands to be defined as part of the bot builder, register them automatically on
launch? We have two options: One is to construct handlers from all commands, the other
is to require the user to make a router and allow adhoc command registration (at that point)
we should have an option to delete all commands.
