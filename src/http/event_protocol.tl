local cjson = require("cjson.safe")

local record event_protocol
   schema_version: integer

   record ErrorDetail
      code: string
      reason: string
      message: string
      retryable: boolean
   end

   record ParsedFrame
      ok: boolean
      event: string
      request_id: string
      data: cjson.Object
      code: string
      reason: string
      message: string
      retryable: boolean
   end

   record AckEnvelope
      event: string
      eventId: string
      requestId: string
      schemaVersion: integer
      occurredAt: string
      sentAt: string
      data: cjson.Object
   end

   record ErrorEnvelope
      event: string
      eventId: string
      requestId: string
      schemaVersion: integer
      occurredAt: string
      sentAt: string
      error: ErrorDetail
   end
end

event_protocol.schema_version = 1

local CHANNEL_PREFIX = "matching:position:"

local ERRORS: {string: event_protocol.ErrorDetail} = {
   invalid_json = {
      code = "INVALID_JSON",
      reason = "invalid_json",
      message = "Frame must be a JSON object.",
      retryable = false,
   },
   invalid_payload = {
      code = "INVALID_PAYLOAD",
      reason = "invalid_payload",
      message = "Frame payload is invalid.",
      retryable = false,
   },
   unsupported_schema_version = {
      code = "UNSUPPORTED_SCHEMA_VERSION",
      reason = "unsupported_schema_version",
      message = "Schema version is not supported.",
      retryable = false,
   },
   invalid_order_id = {
      code = "INVALID_ORDER_ID",
      reason = "invalid_order_id",
      message = "A valid orderId is required.",
      retryable = false,
   },
   order_not_found = {
      code = "ORDER_NOT_FOUND",
      reason = "order_not_found",
      message = "The requested order was not found.",
      retryable = false,
   },
   forbidden = {
      code = "FORBIDDEN",
      reason = "forbidden",
      message = "You are not authorized to perform this action.",
      retryable = false,
   },
   upstream_unavailable = {
      code = "UPSTREAM_UNAVAILABLE",
      reason = "upstream_unavailable",
      message = "Upstream service is temporarily unavailable.",
      retryable = true,
   },
   unknown_event = {
      code = "UNKNOWN_EVENT",
      reason = "unknown_event",
      message = "Unknown event name.",
      retryable = false,
   },
}

local function frame_error(request_id: string, key: string): event_protocol.ParsedFrame
   local detail = ERRORS[key] or ERRORS["invalid_payload"]
   return {
      ok = false,
      request_id = request_id,
      code = detail.code,
      reason = detail.reason,
      message = detail.message,
      retryable = detail.retryable,
   }
end

function event_protocol.error_detail(key: string): event_protocol.ErrorDetail
   return ERRORS[key] or ERRORS["invalid_payload"]
end

function event_protocol.bearer_token(header: string): string
   if header == nil then
      return nil
   end

   local scheme, token = string.match(header, "^%s*([%a]+)%s+(.-)%s*$")
   if scheme == nil or string.lower(scheme) ~= "bearer" or token == "" then
      return nil
   end

   return token
end

function event_protocol.uuid_from_hex(hex32: string): string
   if hex32 == nil or #hex32 ~= 32 then
      return nil
   end

   local lower = string.lower(hex32)
   if string.match(lower, "^%x+$") == nil then
      return nil
   end

   local variant_nibble = (tonumber(string.sub(lower, 17, 17), 16) % 4) + 8
   return string.sub(lower, 1, 8)
      .. "-"
      .. string.sub(lower, 9, 12)
      .. "-4"
      .. string.sub(lower, 14, 16)
      .. "-"
      .. string.format("%x", variant_nibble)
      .. string.sub(lower, 18, 20)
      .. "-"
      .. string.sub(lower, 21, 32)
end

function event_protocol.is_uuid(value: string): boolean
   if value == nil then
      return false
   end

   local pattern = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
   return string.match(string.lower(value), pattern) ~= nil
end

function event_protocol.subscription_channel(order_number: string): string
   return CHANNEL_PREFIX .. order_number
end

function event_protocol.ws_url(base_url: string, path: string): string
   local replaced = base_url
   if string.sub(base_url, 1, 8) == "https://" then
      replaced = "wss://" .. string.sub(base_url, 9)
   elseif string.sub(base_url, 1, 7) == "http://" then
      replaced = "ws://" .. string.sub(base_url, 8)
   end

   return (string.gsub(replaced, "/$", "")) .. path
end

function event_protocol.parse_frame(raw: string): event_protocol.ParsedFrame
   local decoded = cjson.decode(raw)
   if not (decoded is cjson.Document) then
      return frame_error(nil, "invalid_json")
   end

   local raw_request_id = decoded["requestId"]
   local request_id: string = nil
   if raw_request_id is string and raw_request_id ~= "" then
      request_id = raw_request_id
   end

   local event = decoded["event"]
   if not (event is string) or event == "" then
      return frame_error(request_id, "invalid_payload")
   end

   local version = decoded["schemaVersion"]
   if version ~= nil then
      if not (version is number) or math.floor(version) ~= event_protocol.schema_version then
         return frame_error(request_id, "unsupported_schema_version")
      end
   end

   local raw_data = decoded["data"]
   local data: cjson.Object = {}
   if raw_data ~= nil then
      if not (raw_data is cjson.Object) then
         return frame_error(request_id, "invalid_payload")
      end

      data = raw_data
   end

   return {
      ok = true,
      event = event,
      request_id = request_id,
      data = data,
   }
end

function event_protocol.ack_json(
   request_id: string,
   data: cjson.Object,
   event_id: string,
   now_iso: string
): string
   local envelope: event_protocol.AckEnvelope = {
      event = "command.ack",
      eventId = event_id,
      requestId = request_id,
      schemaVersion = event_protocol.schema_version,
      occurredAt = now_iso,
      sentAt = now_iso,
      data = data,
   }

   local encoded = cjson.encode(envelope)
   return encoded
end

function event_protocol.pong_json(request_id: string, event_id: string, now_iso: string): string
   local envelope: event_protocol.AckEnvelope = {
      event = "system.pong",
      eventId = event_id,
      requestId = request_id,
      schemaVersion = event_protocol.schema_version,
      occurredAt = now_iso,
      sentAt = now_iso,
      data = {},
   }

   local encoded = cjson.encode(envelope)
   return encoded
end

function event_protocol.error_json(
   request_id: string,
   detail: event_protocol.ErrorDetail,
   event_id: string,
   now_iso: string
): string
   local envelope: event_protocol.ErrorEnvelope = {
      event = "command.error",
      eventId = event_id,
      requestId = request_id,
      schemaVersion = event_protocol.schema_version,
      occurredAt = now_iso,
      sentAt = now_iso,
      error = detail,
   }

   local encoded = cjson.encode(envelope)
   return encoded
end

return event_protocol
