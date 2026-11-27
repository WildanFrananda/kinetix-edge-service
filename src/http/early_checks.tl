local context = require("http.context")
local csrf = require("http.csrf")
local http = require("resty.http")
local json_relay = require("adapters.json_relay")
local type ApiRouteRule = require("types.api_route_rule")
local type EarlyCheckResult = require("types.early_check_result")

local record early_checks
end

local BODY_METHODS: {string: boolean} = {
   ["POST"] = true,
   ["PUT"] = true,
   ["PATCH"] = true,
   ["DELETE"] = true,
}

local MAX_IDEMPOTENCY_LEN = 128

local function fail(error_code: string, reason: string): EarlyCheckResult
   return {
      ok = false,
      error_code = error_code,
      reason = reason,
   }
end

local function valid_idempotency_key(value: string): boolean
   if value == nil then
      return false
   end

   local trimmed = string.gsub(value, "^%s*(.-)%s*$", "%1")
   if trimmed == "" or #trimmed > MAX_IDEMPOTENCY_LEN then
      return false
   end

   return string.match(trimmed, "^[%g ]+$") ~= nil
end

local function has_declared_body(headers: {string: http.HeaderValue}): boolean
   local length = context.single(headers, "content-length")
   if length ~= nil and length ~= "0" then
      return true
   end

   return headers["transfer-encoding"] ~= nil
end

function early_checks.evaluate(
   rule: ApiRouteRule,
   method: string,
   headers: {string: http.HeaderValue},
   read_body: function(): string
): EarlyCheckResult
   if rule.require_idempotency and method == "POST" then
      local key = context.single(headers, "idempotency-key")
      if not valid_idempotency_key(key) then
         return fail("IDEMPOTENCY_KEY_REQUIRED", "idempotency_key_required")
      end
   end

   if not BODY_METHODS[method] then
      return { ok = true }
   end

   local raw_length = context.single(headers, "content-length")
   if raw_length ~= nil then
      if string.match(raw_length, "^%d+$") == nil then
         return fail("INVALID_REQUEST", "invalid_content_length")
      end

      local declared = tonumber(raw_length)
      if declared == nil or declared > rule.max_body_bytes then
         return fail("PAYLOAD_TOO_LARGE", "payload_too_large")
      end
   end

   local body = read_body()
   if body == nil or #body > rule.max_body_bytes then
      return fail("PAYLOAD_TOO_LARGE", "payload_too_large")
   end

   local has_body = #body > 0 or has_declared_body(headers)
   if rule.require_json and has_body then
      if not csrf.is_json(context.single(headers, "content-type")) then
         return fail("JSON_REQUIRED", "json_required")
      end

      if not json_relay.is_valid_json(body) then
         return fail("INVALID_REQUEST", "invalid_json")
      end
   end

   return { ok = true, body = body }
end

return early_checks
