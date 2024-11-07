import src/client
import std/envvars
import std/json

proc postgres_changes_callback(payload: JsonNode) =
  echo "postgres_changes_callback!"
  echo payload

proc delete_callback(payload: JsonNode) =
  echo "delete statement reached!"
  echo payload

var 
  url = getEnv("SUPABASE_URL")
  key = getEnv("SUPABASE_KEY")
var rclient = newRealtimeClient(url, key, auto_reconnect = true)
var chan = rclient.setChannel("broadcast-test", broadcast_config)

rclient.join(chan)
chan.on_postgres_changes(PostgresChanges.INSERT, postgres_changes_callback)
chan.on_postgres_changes(PostgresChanges.DELETE, delete_callback)
rclient.subscribe(chan)
rclient.listen()

