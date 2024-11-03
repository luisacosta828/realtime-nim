import src/client
import std/envvars

var 
  url = getEnv("SUPABASE_URL")
  key = getEnv("SUPABASE_KEY")
var rclient = newRealtimeClient(url, key)
var chan = rclient.setChannel("broadcast-test", broadcast_config)

echo rclient.join("broadcast-test")
chan.on_postgres_changes("INSERT")
echo rclient.listen()
echo rclient.getChannels()

