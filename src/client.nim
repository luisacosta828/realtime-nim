# Websockets-based client for Elixir Phoenix Channels,
# that also implements a Supabase Realtime client on top.
# Elixir Phoenix Channels are basically just a websocket.
import whisky  # https://github.com/guzba/whisky
import std/[tables, json]
const
  DEFAULT_TIMEOUT = 10
  PHOENIX_CHANNEL = "phoenix"

type
  RealtimeChannelConfig {.pure.} = enum
    broadcast = "broadcast"
    presence  = "presence"

  RealtimeChannelOptions = object
    case config: RealtimeChannelConfig
    of broadcast: 
      ack, self: bool
    of presence:
      key: string
    private: bool

  Callback[ParamSpec, RetVal] = proc(arg: ParamSpec): RetVal
  CallbackListener = tuple[event: string]

  Binding = object
    `type`: string
    filter: Table[string, string]

  Channel = object
    topic: string
    params: RealtimeChannelOptions
    listeners: seq[CallbackListener]
    joined: bool
    bindings: Table[string, seq[Binding]]

  RealtimeClient* = object
    channels*: TableRef[string, Channel]
    url*: string
    client: WebSocket
    auto_reconnect: bool
    initial_backoff: float
    max_retries: int

  ChannelStates* {.pure.} = enum
    joined  = "joined"
    closed  = "closed"
    errored = "errored"
    joining = "joining"
    leaving = "leaving"

  RealTimeSubscribeState* {.pure.} = enum
    subscribed    = "subscribed"
    timed_out     = "timed_out"
    closed        = "closed"
    channel_error = "channel_error"

  RealTimePresenceListenEvents* {.pure.} = enum
    sync = "sync"
    join = "join"
    leave = "leave"

func connect*(self: RealtimeClient) {.inline.} = discard  # Do nothing?.

proc newRealtimeClient*(url: string, token: string): RealtimeClient = 
  let
    client   = newWebSocket(url & "/websocket?apikey=" & token)
    channels = newTable[string, Channel]()
  RealtimeClient(url: url, client: client, channels: channels, initial_backoff: 1.0, max_retries: 5)


template broadcast_config*():RealtimeChannelOptions =
  RealtimeChannelOptions(config: broadcast, self: true)


proc setChannel*(self: RealtimeClient, topic: string, params: RealtimeChannelOptions): Channel =
  if topic.len > 0: 
    let channel_topic = "realtime:" & topic
    result = Channel(topic: channel_topic, params: params)
    self.channels[channel_topic] = result

proc getChannels*(self: RealtimeClient): seq[Channel] = 
  for item in self.channels.values:
    result.add(item)

proc removeChannel*(self: RealtimeClient, channel: Channel) =
  if channel.topic in self.channels:
    self.channels.del(channel.topic)

  if self.channels.len == 0:
    #close
    discard

proc summary*(self: RealtimeClient) =
  for topic, chans in self.channels.pairs():
    for event in chans.listeners:
      echo "Topic " & topic & " | Event " & $event

proc listen*(self: RealtimeClient): auto =
  self.client.receiveMessage()

proc join*(self: RealtimeClient, topic: string): Channel =
  var params = self.channels["realtime:" & topic].params
  var j2     = %* {"topic": "realtime:"&topic, "event": "phx_join", "ref": nil, "payload": %*{"config": params}}

  self.client.send($j2)


proc on(self: var Channel, topic: string, filter: Table[string, string]) =
  if topic notin self.bindings:
    self.bindings[topic] = @[]
  self.bindings[topic].add Binding(`type`: topic, filter: filter)
  
proc on_postgres_changes*(self: var Channel, event: string, table: string = "*", schema: string = "public", filter: string = "") =
  let bindings_filters = {"event": event, "schema": schema, "table": table}.toTable
  self.on("postgres_changes", filter=bindings_filters)
  echo self.bindings
