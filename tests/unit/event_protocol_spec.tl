local cjson = require("cjson.safe")
local check = require("tests.support.check")
local event_protocol = require("http.event_protocol")

describe("event_protocol", function()
   it("extracts bearer tokens case-insensitively and ignores invalid headers", function()
      check.equal(event_protocol.bearer_token("Bearer tok-123"), "tok-123", "standard bearer")
      check.equal(event_protocol.bearer_token("bearer   tok-456  "), "tok-456", "lowercase trimmed")
      check.absent(event_protocol.bearer_token("Basic abc"), "wrong scheme")
      check.absent(event_protocol.bearer_token("Bearer   "), "empty token")
      check.absent(event_protocol.bearer_token(nil), "nil header")
   end)

   it("formats RFC 9562 UUIDv4 strings from 32 hex chars", function()
      local id = event_protocol.uuid_from_hex("0123456789abcdef0123456789abcdef")
      check.equal(id, "01234567-89ab-4def-8123-456789abcdef", "formatted v4 variant")
      check.absent(event_protocol.uuid_from_hex("short"), "rejects short hex")
      check.truthy(event_protocol.is_uuid(id), "valid uuid")
      check.falsy(event_protocol.is_uuid("ORD-123"), "order number is not uuid")
   end)

   it("maps HTTP base URLs to WebSocket URLs and formats Redis channels", function()
      check.equal(
         event_protocol.ws_url("http://kinetix:8000/", "/ws/v1/events"),
         "ws://kinetix:8000/ws/v1/events",
         "ws"
      )
      check.equal(
         event_protocol.ws_url("https://api.kinetix.id", "/ws/v1/events"),
         "wss://api.kinetix.id/ws/v1/events",
         "wss"
      )
      check.equal(event_protocol.subscription_channel("ORD-99"), "matching:position:ORD-99", "channel")
   end)

   it("validates incoming frames and rejects malformed payloads or unsupported schema versions", function()
      local good = event_protocol.parse_frame(
         '{"event":"subscription.subscribe","requestId":"req-1","schemaVersion":1,"data":{"orderId":"o1"}}'
      )
      check.truthy(good.ok, "valid frame")
      check.equal(good.event, "subscription.subscribe", "event name")
      check.equal(good.request_id, "req-1", "requestId")
      check.equal(good.data["orderId"], "o1", "data field")

      local bad_ver = event_protocol.parse_frame('{"event":"system.ping","requestId":"req-2","schemaVersion":2}')
      check.falsy(bad_ver.ok, "unsupported schema version rejected")
      check.equal(bad_ver.code, "UNSUPPORTED_SCHEMA_VERSION", "code")
      check.equal(bad_ver.request_id, "req-2", "keeps requestId")

      local bad_json = event_protocol.parse_frame("{not-json")
      check.falsy(bad_json.ok, "invalid json rejected")
      check.equal(bad_json.code, "INVALID_JSON", "invalid json code")
   end)

   it("encodes camelCase ack, pong, and error envelopes", function()
      local ack = cjson.decode(event_protocol.ack_json("req-9", { accepted = true }, "evt-9", "2026-11-16T00:00:00Z"))
      local ack_doc = ack as cjson.Document
      check.equal(ack_doc["event"], "command.ack", "ack event")
      check.equal(ack_doc["eventId"], "evt-9", "ack eventId")
      check.equal(ack_doc["requestId"], "req-9", "ack requestId")
      check.equal(ack_doc["schemaVersion"], 1, "schemaVersion")

      local pong = cjson.decode(event_protocol.pong_json("req-10", "evt-10", "2026-11-16T00:00:00Z"))
      check.equal((pong as cjson.Document)["event"], "system.pong", "pong event")

      local detail = event_protocol.error_detail("forbidden")
      local err = cjson.decode(event_protocol.error_json("req-11", detail, "evt-11", "2026-11-16T00:00:00Z"))
      local err_doc = err as cjson.Document
      check.equal(err_doc["event"], "command.error", "error event")
      check.equal((err_doc["error"] as cjson.Object)["code"], "FORBIDDEN", "error code")
   end)
end)
