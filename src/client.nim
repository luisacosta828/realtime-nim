# Websockets-based client for Elixir Phoenix Channels,
# that also implements a Supabase Realtime client on top.
# Elixir Phoenix Channels are basically just a websocket.
import whisky  # https://github.com/guzba/whisky
import std/[tables, json]
from std/strutils import strip

const
  DEFAULT_TIMEOUT = 10
  PHOENIX_CHANNEL = "phoenix"
  RealtimePostgresChangesListenEvent = ["*", "INSERT", "DELETE", "UPDATE"]

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
    access_token: string
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
  RealtimeClient(url: url, client: client, channels: channels, initial_backoff: 1.0, max_retries: 5, access_token: token)


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

proc join*(self: RealtimeClient, channel: Channel) =
  var j2  = %* {"topic": channel.topic, "event": "phx_join", "ref": nil, "payload": %*{"config": channel.params}}
  self.client.send($j2)

proc on(self: var Channel, topic: string, filter: Table[string, string]) =
  if topic notin self.bindings:
    self.bindings[topic] = @[]
  self.bindings[topic].add Binding(`type`: topic, filter: filter)
  
proc on_postgres_changes*(self: var Channel, event: string, table: string = "*", schema: string = "public", filter: string = "") =
  if event in RealtimePostgresChangesListenEvent:
    var bindings_filters = {"event": event, "schema": schema, "table": table}.toTable
    if filter.strip.len > 0:
      bindings_filters["filter"] = filter
    self.on("postgres_changes", filter=bindings_filters)

proc subscribe*(self: RealtimeClient, channel: Channel) =
  if not self.client.isNil:
    var
      params    = channel.params
      config    = params.config
      broadcast = %* {}
      presence  = %* {}

    if config == RealtimeChannelConfig.broadcast:
      broadcast = %* { "ack": params.ack, "self": params.self }
    else:
      presence = %* { "key": params.key }

    var filters:seq[Table[string, string]]

    for item in channel.bindings["postgres_changes"]:
      filters.add item.filter
      
    let payload = %* {
      "config": %* {
        "private": params.private,
        "broadcast": broadcast,
        "presence": presence,
        "postgres_changes": %filters
      },
      "access_token": self.access_token
    }
    echo payload

