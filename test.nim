import src/client
import std/envvars
import std/json

proc postgres_changes_callback(payload: JsonNode) =
  echo payload

var 
  url = getEnv("SUPABASE_URL")
  key = getEnv("SUPABASE_KEY")
var rclient = newRealtimeClient(url, key)
var chan = rclient.setChannel("broadcast-test", broadcast_config)


rclient.join(chan)
chan.on_postgres_changes("INSERT", postgres_changes_callback)
rclient.subscribe(chan)
rclient.listen()

