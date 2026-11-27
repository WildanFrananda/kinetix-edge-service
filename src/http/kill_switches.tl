local clock = require("adapters.clock")
local digest = require("adapters.digest")
local kill_switch_store = require("adapters.kill_switch_store")
local kill_switches_config = require("config.kill_switches")
local logger = require("adapters.logger")
local type Environment = require("types.environment")
local type KillSwitchCheck = require("types.kill_switch_check")
local type KillSwitchRule = require("types.kill_switch_rule")
local type KillSwitchState = require("types.kill_switch_state")

local record kill_switches
end

local DEFAULT_TTL_SECONDS = 3600

local function default_state(rule: KillSwitchRule): KillSwitchState
   return {
      feature = rule.feature,
      enabled = false,
      reason = "",
      messageKey = rule.default_message_key,
      retryAfter = rule.default_retry_after,
      updatedAt = "",
      updatedBy = "",
      expiresAt = "",
   }
end

function kill_switches.is_known(feature: string): boolean
   return kill_switches_config.find(feature) ~= nil
end

function kill_switches.evaluate_state(
   state: KillSwitchState,
   unavailable: boolean,
   feature: string
): KillSwitchCheck
   if unavailable then
      return {
         ok = false,
         unavailable = true,
         feature = feature,
      }
   end

   if state == nil or not state.enabled then
      return {
         ok = true,
         unavailable = false,
         feature = feature,
      }
   end

   local rule = kill_switches_config.find(feature)
   local fallback_key = rule ~= nil and rule.default_message_key or "MAINTENANCE_MODE"
   local fallback_retry = rule ~= nil and rule.default_retry_after or 60
   local message_key = state.messageKey ~= "" and state.messageKey or fallback_key
   local retry_after = state.retryAfter > 0 and state.retryAfter or fallback_retry

   return {
      ok = false,
      unavailable = false,
      feature = feature,
      message_key = message_key,
      retry_after = tostring(retry_after),
   }
end

function kill_switches.evaluate(environment: Environment, feature: string): KillSwitchCheck
   if feature == nil or feature == "" then
      return { ok = true, unavailable = false }
   end

   local state, unavailable = kill_switch_store.read(environment, string.lower(feature))
   return kill_switches.evaluate_state(state, unavailable, string.lower(feature))
end

function kill_switches.get_state(environment: Environment, feature: string): KillSwitchState, boolean
   local rule = kill_switches_config.find(feature)
   if rule == nil then
      return nil, false
   end

   local state, unavailable = kill_switch_store.read(environment, rule.feature)
   if unavailable then
      return nil, true
   end

   if state == nil then
      return default_state(rule), false
   end

   return state, false
end

function kill_switches.list(environment: Environment): {KillSwitchState}, boolean
   local items: {KillSwitchState} = {}
   for _, feature in ipairs(kill_switches_config.features) do
      local state, unavailable = kill_switches.get_state(environment, feature)
      if unavailable then
         return nil, true
      end

      table.insert(items, state)
   end

   return items, false
end

function kill_switches.update(
   environment: Environment,
   feature: string,
   actor_principal_id: string,
   enabled: boolean,
   message_key: string,
   retry_after: integer,
   ttl_seconds: integer,
   reason: string,
   request_id: string
): KillSwitchState, boolean
   local rule = kill_switches_config.find(feature)
   if rule == nil then
      return nil, false
   end

   local now_ms = clock.now_ms()
   local now_iso = clock.iso8601(now_ms)
   local actor_tag = digest.sha256_hex(actor_principal_id or "")

   if not enabled then
      local removed = kill_switch_store.disable(environment, rule.feature)
      if not removed then
         return nil, true
      end

      logger.info(
         "kill_switch_audit",
         {
            action = "disable",
            feature = rule.feature,
            actor = actor_tag,
            request_id = request_id,
         }
      )
      local reset_state = default_state(rule)
      reset_state.updatedAt = now_iso
      reset_state.updatedBy = actor_tag
      return reset_state, false
   end

   local ttl = ttl_seconds or DEFAULT_TTL_SECONDS
   local retry = retry_after or rule.default_retry_after
   local key_out = message_key ~= nil and message_key ~= "" and message_key or rule.default_message_key
   local expires_iso = clock.iso8601(now_ms + ttl * 1000)

   local state: KillSwitchState = {
      feature = rule.feature,
      enabled = true,
      reason = reason or "",
      messageKey = key_out,
      retryAfter = retry,
      updatedAt = now_iso,
      updatedBy = actor_tag,
      expiresAt = expires_iso,
   }

   local saved = kill_switch_store.enable(environment, state, ttl)
   if not saved then
      return nil, true
   end

   logger.info(
      "kill_switch_audit",
      {
         action = "enable",
         feature = rule.feature,
         actor = actor_tag,
         retry_after = retry,
         ttl_seconds = ttl,
         request_id = request_id,
      }
   )
   return state, false
end

return kill_switches
