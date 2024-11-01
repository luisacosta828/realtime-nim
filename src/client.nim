# Websockets-based client for Elixir Phoenix Channels,
# that also implements a Supabase Realtime client on top.
# Elixir Phoenix Channels are basically just a websocket.
import whisky  # https://github.com/guzba/whisky
import std/tables
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

  Channel = object
    topic: string
    params: RealtimeChannelOptions
    listeners: seq[CallbackListener]
    joined: bool

  RealtimeClient* = object
    channels*: TableRef[string, Channel]
    url*: string
    client: WebSocket

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
  RealtimeClient(url: url, client: newWebSocket(url & "/websocket?apikey=" & token), channels: newTable[string, Channel]())

template setChannel*(self: RealtimeClient; topic: string, params: RealtimeChannelOptions) =
  if topic.len > 0: 
    const channel_topic = "realtime:" & topic
    self.channels[channel_topic] = Channel(topic: channel_topic, params)

func getChannels*(self: RealtimeClient): seq[Channel] = 
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
  # https://github.com/supabase-community/realtime-py/blob/8bcf6da63e161d7127292a079887952d2c8a2722/realtime/connection.py#L59-L66
  discard
