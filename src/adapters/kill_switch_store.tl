local cjson = require("cjson.safe")
local metrics = require("adapters.metrics")
local redis_store = require("adapters.redis_store")
local type Environment = require("types.environment")
local type KillSwitchState = require("types.kill_switch_state")

local record kill_switch_store
end

local KEY_PREFIX = "edge:kill:"

function kill_switch_store.key_of(feature: string): string
   return KEY_PREFIX .. feature
end

local function decode_state(raw: string): KillSwitchState
   if raw == nil or raw == "" then
      return nil
   end

   local decoded = cjson.decode(raw)
   if not (decoded is cjson.Document) then
      return nil
   end

   local feature = decoded["feature"]
   local enabled = decoded["enabled"]
   local message_key = decoded["messageKey"]
   local retry_after = decoded["retryAfter"]
   if not (feature is string) or not (enabled is boolean) then
      return nil
   end

   local reason = decoded["reason"]
   local updated_at = decoded["updatedAt"]
   local updated_by = decoded["updatedBy"]
   local expires_at = decoded["expiresAt"]

   return {
      feature = feature,
      enabled = enabled,
      reason = reason is string and reason or "",
      messageKey = message_key is string and message_key or "",
      retryAfter = retry_after is number and math.floor(retry_after) or 60,
      updatedAt = updated_at is string and updated_at or "",
      updatedBy = updated_by is string and updated_by or "",
      expiresAt = expires_at is string and expires_at or "",
   }
end

function kill_switch_store.read(environment: Environment, feature: string): KillSwitchState, boolean
   local client = redis_store.open(environment)
   if client == nil then
      metrics.dependency_failed("redis")
      return nil, true
   end

   local raw, failure = redis_store.read(client, kill_switch_store.key_of(feature))
   if failure ~= nil then
      metrics.dependency_failed("redis")
      return nil, true
   end

   redis_store.release(client)
   return decode_state(raw), false
end

function kill_switch_store.enable(
   environment: Environment,
   state: KillSwitchState,
   ttl_seconds: integer
): boolean
   local client = redis_store.open(environment)
   if client == nil then
      metrics.dependency_failed("redis")
      return false
   end

   local encoded = cjson.encode(state)
   if encoded == nil then
      redis_store.discard(client)
      return false
   end

   local reply, failure = client:set(
      kill_switch_store.key_of(state.feature),
      encoded,
      "PX",
      tostring(ttl_seconds * 1000)
   )
   if not reply then
      redis_store.discard(client)
      metrics.dependency_failed("redis")
      return false
   end

   redis_store.release(client)
   return failure == nil
end

function kill_switch_store.disable(environment: Environment, feature: string): boolean
   local client = redis_store.open(environment)
   if client == nil then
      metrics.dependency_failed("redis")
      return false
   end

   local ok = redis_store.delete(client, { kill_switch_store.key_of(feature) })
   if not ok then
      metrics.dependency_failed("redis")
      return false
   end

   redis_store.release(client)
   return true
end

return kill_switch_store
