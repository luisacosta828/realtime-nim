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
  PostgresChanges* {.pure.} = enum
    ALL = "*"
    INSERT = "INSERT"
    DELETE = "DELETE"
    UPDATE = "UPDATE"

  RealtimeChannelConfig {.pure.} = enum
    broadcast = "broadcast"
    presence  = "presence"

  ChannelEvents {.pure.} = enum
    `close` = "phx_close"
    error   = "phx_error"
    join    = "phx_join"
    reply   = "phx_reply"
    leave   = "phx_leave"
    heartbeat = "heartbeat"
    access_token = "access_token"
    broadcast = "broadcast"
    presence = "presence"

  RealtimeChannelOptions = object
    case config: RealtimeChannelConfig
    of broadcast: 
      ack, self: bool
    of presence:
      key: string
    private: bool

  Callback = proc(arg: JsonNode)
  CallbackListener = tuple[event: string, callback: Callback]

  Binding = object
    `type`: string
    filter: Table[string, string]
    callback: Callback

  Channel = ref object
    topic: string
    params: RealtimeChannelOptions
    listeners: seq[CallbackListener]
    joined: bool
    state: ChannelStates
    bindings: Table[string, seq[Binding]]
    join_push: AsyncPush

  AsyncPush = ref object
    event: string
    payload: JsonNode
    reference: ref int

  RealtimeClient* = ref object
    channels*: TableRef[string, Channel]
    url*: string
    access_token: string
    client: WebSocket
    auto_reconnect: bool
    initial_backoff: float
    max_retries: Positive
    reference: int

  ChannelStates {.pure.} = enum
    joined  = "joined"
    closed  = "closed"
    errored = "errored"
    joining = "joining"
    leaving = "leaving"

  RealTimeSubscribeState {.pure.} = enum
    subscribed    = "subscribed"
    timed_out     = "timed_out"
    closed        = "closed"
    channel_error = "channel_error"

  RealTimePresenceListenEvents {.pure.} = enum
    sync = "sync"
    join = "join"
    leave = "leave"


template connect*(self: RealtimeClient) =  
  self.client   = newWebSocket(self.url & "/websocket?apikey=" & self.access_token)

proc newRealtimeClient*(url: string, token: string, channels: TableRef[string, Channel] = newTable[string,Channel](), auto_reconnect: bool = false): RealtimeClient = 
  result = RealtimeClient(url: url, channels: channels, initial_backoff: 1.0, max_retries: 5, access_token: token, auto_reconnect: auto_reconnect)
  result.connect()


template broadcast_config*():RealtimeChannelOptions =
  RealtimeChannelOptions(config: RealtimeChannelConfig.broadcast, self: true)

proc initAsyncPush(event: string, payload: RealtimeChannelOptions): AsyncPush = AsyncPush(event: event, payload: %*{})

proc setChannel*(self: RealtimeClient, topic: string, params: RealtimeChannelOptions): Channel =
  if topic.len > 0: 
    let channel_topic = "realtime:" & topic
    result = Channel(topic: channel_topic, params: params, join_push: initAsyncPush($ChannelEvents.join, params))
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

proc trigger(self: Channel, topic: string, payload: JsonNode, reference: string) =
  let payload_fields = payload.getFields
  if topic in self.bindings:
    for binding in self.bindings[topic]:
      if topic in ["broadcast", "postgres_changes", "presence"]:
        var 
          binding_event = binding.filter.getOrDefault("event")
          data_type = payload_fields["data"].getFields()["type"].getStr

        if binding_event == data_type:
          binding.callback(payload)


template resend(self: RealtimeClient, channel: Channel, push: AsyncPush) =
  inc(self.reference)
  var msg = %* {
    "topic": channel.topic,
    "event": push.event,
    "payload": push.payload,
    "ref": $self.reference
  }
  self.client.send($msg)
  

template rejoin(self: RealtimeClient, channel: Channel) =
  channel.state = ChannelStates.joining
  self.resend(channel, channel.join_push)

template update_payload(self: AsyncPush, payload: JsonNode) = self.payload = payload

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
    channel.join_push.update_payload(payload)
    self.rejoin(channel)

proc join*(self: RealtimeClient, channel: Channel) =
  var j2  = %* {"topic": channel.topic, "event": "phx_join", "ref": nil, "payload": %*{"config": channel.params}}
  self.client.send($j2)

template rejoin =
  if self.auto_reconnect:
    echo "Connection with server closed, trying to reconnect..."
    self.connect()
    for channel in self.channels.values():
      self.rejoin(channel)
  else:
    echo "Connection with the server closed."
    break

template retry(body: untyped) =
  while true:
    try:
      body
    except:
      rejoin()

proc listen*(self: RealtimeClient): auto =
  var 
    raw_msg:  Option[Message]
    json_msg: JsonNode
    channel:  Channel
    payload:  JsonNode

  retry:
    raw_msg  = self.client.receiveMessage()
    json_msg = parseJson(raw_msg.get.data)
    if json_msg["topic"].getStr in self.channels:
      channel  = self.channels[json_msg["topic"].getStr]
      payload  = json_msg["payload"]
      channel.trigger(json_msg["event"].getStr, payload, json_msg["ref"].getStr)

proc on(self: var Channel, topic: string, filter: Table[string, string], callback: Callback) =
  if topic notin self.bindings:
    self.bindings[topic] = @[]
  self.bindings[topic].add Binding(`type`: topic, filter: filter, callback: callback)
  
proc on_postgres_changes*(self: var Channel, event: PostgresChanges, callback: Callback, table: string = "*", schema: string = "public", filter: string = "") =
  if $event in RealtimePostgresChangesListenEvent:
    var bindings_filters = {"event": $event, "schema": schema, "table": table}.toTable
    if filter.strip.len > 0:
      bindings_filters["filter"] = filter
    self.on("postgres_changes", filter=bindings_filters, callback)
