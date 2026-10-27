local clock = require("adapters.clock")
local identity_answers = require("http.identity_answers")
local identity_client = require("adapters.identity_client")
local lifetimes = require("http.lifetimes")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local timing = require("config.timing")
local type EndReason = require("types.end_reason")
local type RequestContext = require("types.request_context")
local type Session = require("types.session")
local type UpstreamReply = require("types.upstream_reply")

local record revocation
end

local function unusable(reply: UpstreamReply): boolean
   if not reply.reached or reply.status >= 500 or reply.status == 429 then
      return true
   end

   return identity_answers.is_client_refusal(identity_answers.error_code(identity_answers.document(reply.body)))
end

local function failed(request: RequestContext, reason: EndReason, step: string, reply: UpstreamReply)
   if not reply.reached or reply.status >= 500 then
      metrics.dependency_failed("identity")
   end

   metrics.session_revocation(request.app.name, "failed")
   logger.warn(
      "session_revocation_failed",
      {
         reason = reason,
         step = step,
         status = reply.status or 0,
         cause = reply.cause or "",
         request_id = request.request_id,
      }
   )
end

local function settled(request: RequestContext, reason: EndReason, outcome: string)
   metrics.session_revocation(request.app.name, outcome)
   logger.info(
      "session_revoked",
      { reason = reason, outcome = outcome, app = request.app.name, request_id = request.request_id }
   )
end

local function revoke(request: RequestContext, session: Session, reason: EndReason)
   local access_token = session.access_token
   local refresh_token = session.refresh_token
   if lifetimes.needs_refresh(session, clock.now_ms(), timing.refresh_before_ms) then
      local renewed = identity_client.refresh(request, refresh_token)
      if unusable(renewed) then
         return failed(request, reason, "refresh", renewed)
      end

      if renewed.status ~= 200 then
         return settled(request, reason, "already_revoked")
      end

      local grant = identity_answers.grant(identity_answers.document(renewed.body))
      if grant == nil then
         return failed(request, reason, "refresh", renewed)
      end

      access_token = grant.access_token
      refresh_token = grant.refresh_token
   end

   local reply = identity_client.logout(request, access_token, refresh_token)
   if unusable(reply) then
      return failed(request, reason, "logout", reply)
   end

   if reply.status == 401 or reply.status == 403 then
      return settled(request, reason, "already_revoked")
   end

   if reply.status >= 300 then
      return failed(request, reason, "logout", reply)
   end

   settled(request, reason, "revoked")
end

function revocation.schedule(request: RequestContext, session: Session, reason: EndReason)
   local scheduled, failure = ngx.timer.at(0, function(_: boolean)
      revoke(request, session, reason)
   end)
   if scheduled then
      return
   end

   metrics.session_revocation(request.app.name, "failed")
   logger.warn(
      "session_revocation_failed",
      { reason = reason, step = "schedule", cause = failure or "", request_id = request.request_id }
   )
end

return revocation
