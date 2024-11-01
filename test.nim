import src/client
import std/envvars

var 
  url = getEnv("SUPABASE_URL")
  key = getEnv("SUPABASE_KEY")
var rclient = newRealtimeClient(url, key)
echo $rclient
echo rclient.getChannels()
rclient.summary()
