local clock = require("adapters.clock")
local digest = require("adapters.digest")
local secure_random = require("adapters.secure_random")
local socket_cap_store = require("adapters.socket_cap_store")
local socket_caps_config = require("config.socket_caps")
local type Environment = require("types.environment")

local record socket_caps
end

function socket_caps.key_of(principal_id: string): string
   return "edge:ws:cap:" .. digest.sha256_hex(principal_id)
end

function socket_caps.new_connection_id(): string
   local random_hex = secure_random.hex(8)
   if random_hex ~= nil then
      return random_hex
   end

   return string.format("conn-%d-%d", ngx.worker.pid(), clock.now_ms())
end

function socket_caps.acquire(
   environment: Environment,
   principal_id: string,
   role: string,
   conn_id: string
): boolean, boolean
   if principal_id == nil or principal_id == "" or conn_id == nil or conn_id == "" then
      return false, true
   end

   local key = socket_caps.key_of(principal_id)
   local limit = socket_caps_config.limit_for_role(role)
   return socket_cap_store.acquire(
      environment,
      key,
      conn_id,
      limit,
      clock.now_ms(),
      socket_caps_config.slot_ttl_ms
   )
end

function socket_caps.renew(environment: Environment, principal_id: string, conn_id: string): boolean
   if principal_id == nil or principal_id == "" or conn_id == nil or conn_id == "" then
      return false
   end

   return socket_cap_store.renew(
      environment,
      socket_caps.key_of(principal_id),
      conn_id,
      clock.now_ms(),
      socket_caps_config.slot_ttl_ms
   )
end

function socket_caps.release(environment: Environment, principal_id: string, conn_id: string)
   if principal_id == nil or principal_id == "" or conn_id == nil or conn_id == "" then
      return
   end

   socket_cap_store.release(
      environment,
      socket_caps.key_of(principal_id),
      conn_id,
      clock.now_ms(),
      socket_caps_config.slot_ttl_ms
   )
end

return socket_caps
