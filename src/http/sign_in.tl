local context = require("http.context")
local cookies = require("http.cookies")
local identity_answers = require("http.identity_answers")
local identity_client = require("adapters.identity_client")
local json_body = require("http.json_body")
local lifetimes = require("http.lifetimes")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local sessions = require("http.sessions")
local clock = require("adapters.clock")
local errors = require("http.errors")
local type RequestContext = require("types.request_context")
local type SessionView = require("types.session_view")
local type TokenGrant = require("types.token_grant")
local type UpstreamReply = require("types.upstream_reply")

local record sign_in
end

local CLIENT_CONFIGURATION_REFUSALS: {string: boolean} = {
   ["UNKNOWN_CLIENT"] = true,
   ["CLIENT_REQUIRED"] = true,
   ["CLIENT_PROOF_REQUIRED"] = true,
   ["CLIENT_PROOF_INVALID"] = true,
}

local function cookie_header(request: RequestContext): string
   return context.joined(request.headers, "cookie", "; ")
end

function sign_in.session_cookie(request: RequestContext): string
   return cookies.read(cookie_header(request), cookies.session_name)
end

function sign_in.pending_cookie(request: RequestContext): string
   return cookies.read(cookie_header(request), cookies.pending_name)
end

local function unreachable(request: RequestContext, reply: UpstreamReply, stage: string)
   metrics.dependency_failed("identity")
   logger.warn(
      "identity_unavailable",
      { stage = stage, status = reply.status or 0, cause = reply.cause or "", request_id = request.request_id }
   )
   respond.error("IDENTITY_UNAVAILABLE", request.request_id, nil)
end

local function not_understood(request: RequestContext, reply: UpstreamReply, stage: string)
   logger.error(
      "identity_answer_not_understood",
      {
         stage = stage,
         status = reply.status or 0,
         error = identity_answers.error_code(identity_answers.document(reply.body)) or "",
         request_id = request.request_id,
      }
   )
   respond.error("IDENTITY_FAILED", request.request_id, nil)
end

local function delayed(request: RequestContext, reply: UpstreamReply)
   local code = identity_answers.error_code(identity_answers.document(reply.body))
   local failure = code == "SIGN_IN_DELAYED"
      and errors.catalogue["SIGN_IN_DELAYED"]
      or errors.catalogue["TOO_MANY_REQUESTS"]

   respond.edge_error(failure, request.request_id, nil, identity_answers.retry_after(reply.headers))
end

local function refused_by_identity(request: RequestContext, reply: UpstreamReply, stage: string): boolean
   if not reply.reached or reply.status >= 500 then
      unreachable(request, reply, stage)
      return true
   end

   if reply.status == 429 then
      delayed(request, reply)
      return true
   end

   local code = identity_answers.error_code(identity_answers.document(reply.body))
   if CLIENT_CONFIGURATION_REFUSALS[code] then
      not_understood(request, reply, stage)
      return true
   end

   return false
end

local function start_session(client: redis.Client, request: RequestContext, grant: TokenGrant, stage: string)
   local pending = sign_in.pending_cookie(request)
   local expire_pending: {string} = {}
   if pending ~= nil then
      table.insert(expire_pending, cookies.expired(cookies.pending_name))
   end

   if not sessions.admits(request.app, grant.role) then
      if pending ~= nil then
         redis_store.delete(client, { sessions.pending_key_of(pending) })
      end

      sessions.log_out_quietly(request, grant, stage)
      logger.info(
         "role_refused",
         { stage = stage, role = grant.role, app = request.app.name, request_id = request.request_id }
      )
      return respond.error("ROLE_REFUSED", request.request_id, expire_pending)
   end

   local value, session, failure = sessions.begin(client, request, grant, sign_in.session_cookie(request), pending)
   if value == nil then
      sessions.log_out_quietly(request, grant, stage)
      return respond.error(failure, request.request_id, nil)
   end

   ngx.var.edge_session_tag = sessions.tag_of(value)

   local set_cookies: {string} = { cookies.session(value, lifetimes.cookie_max_age(request.app)) }
   for _, expired in ipairs(expire_pending) do
      table.insert(set_cookies, expired)
   end

   local view: SessionView = {
      authenticated = true,
      role = session.role,
      principalId = session.principal_id,
      expiresAt = clock.iso8601(lifetimes.ends_at(request.app, session)),
   }

   respond.json(200, view, set_cookies)
end

local function start_pending(
   client: redis.Client,
   request: RequestContext,
   kind: string,
   token: string,
   user_id: integer,
   expires_in: integer
)
   local value, lifetime, failure = sessions.begin_pending(
      client,
      request,
      kind == "challenge" and "challenge" or "enrolment",
      token,
      user_id,
      expires_in,
      sign_in.pending_cookie(request)
   )
   if value == nil then
      return respond.error(failure, request.request_id, nil)
   end

   local set_cookies: {string} = { cookies.pending(value, lifetime) }
   if kind == "challenge" then
      return respond.json(200, { mfaRequired = true }, set_cookies)
   end

   respond.json(200, { mfaEnrolmentRequired = true }, set_cookies)
end

local function open(request: RequestContext): redis.Client
   local client = sessions.open()
   if client == nil then
      respond.error("SESSION_STORE_UNAVAILABLE", request.request_id, nil)
   end

   return client
end

local function settle_login(client: redis.Client, request: RequestContext, reply: UpstreamReply)
   if refused_by_identity(request, reply, "login") then
      return
   end

   if reply.status == 401 then
      return respond.error("SIGN_IN_REFUSED", request.request_id, nil)
   end

   if reply.status == 400 then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   if reply.status ~= 200 then
      return not_understood(request, reply, "login")
   end

   local answer = identity_answers.sign_in(identity_answers.document(reply.body))
   if answer.kind == "session" then
      return start_session(client, request, answer.grant, "login")
   end

   if answer.kind == "challenge" then
      return start_pending(client, request, "challenge", answer.token, nil, answer.expires_in)
   end

   if answer.kind == "enrolment" then
      if not request.app.enrolment then
         logger.info("role_refused", { stage = "enrolment", app = request.app.name, request_id = request.request_id })
         return respond.error("ROLE_REFUSED", request.request_id, nil)
      end

      return start_pending(client, request, "enrolment", answer.token, answer.user_id, answer.expires_in)
   end

   not_understood(request, reply, "login")
end

function sign_in.login(request: RequestContext)
   local body = json_body.object()
   local email = json_body.text(body, "email", 254)
   local password = json_body.text(body, "password", 1024)
   if email == nil or password == nil then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   local client = open(request)
   if client == nil then
      return
   end

   settle_login(client, request, identity_client.login(request, email, password))
   redis_store.release(client)
end

local function settle_verify(client: redis.Client, request: RequestContext, reply: UpstreamReply)
   if refused_by_identity(request, reply, "verify") then
      return
   end

   if reply.status == 401 then
      return respond.error("CODE_REFUSED", request.request_id, nil)
   end

   if reply.status == 400 then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   local grant = reply.status == 200 and identity_answers.grant(identity_answers.document(reply.body)) or nil
   if grant == nil then
      return not_understood(request, reply, "verify")
   end

   start_session(client, request, grant, "verify")
end

local function code_of(request: RequestContext): string
   local code = json_body.text(json_body.object(), "code", 16)
   if code == nil then
      respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   return code
end

local function no_pending(client: redis.Client, request: RequestContext, value: string)
   local set_cookies: {string} = {}
   if value ~= nil then
      redis_store.delete(client, { sessions.pending_key_of(value) })
      table.insert(set_cookies, cookies.expired(cookies.pending_name))
   end

   respond.error("SIGN_IN_REQUIRED", request.request_id, set_cookies)
end

function sign_in.verify(request: RequestContext)
   local code = code_of(request)
   if code == nil then
      return
   end

   local client = open(request)
   if client == nil then
      return
   end

   local value = sign_in.pending_cookie(request)
   local pending, failure = sessions.pending(client, request, value, "challenge")
   if failure ~= nil then
      respond.error(failure, request.request_id, nil)
   elseif pending == nil then
      no_pending(client, request, value)
   else
      settle_verify(client, request, identity_client.verify(request, pending.token, code))
   end

   redis_store.release(client)
end

local function settle_enrolment_refusal(
   client: redis.Client,
   request: RequestContext,
   reply: UpstreamReply,
   value: string
): boolean
   if reply.status == 401 or reply.status == 403 then
      no_pending(client, request, value)
      return true
   end

   if reply.status == 409 then
      respond.error("TWO_FACTOR_ALREADY_ENABLED", request.request_id, nil)
      return true
   end

   return false
end

local function settle_setup(client: redis.Client, request: RequestContext, reply: UpstreamReply, value: string)
   if refused_by_identity(request, reply, "setup") or settle_enrolment_refusal(client, request, reply, value) then
      return
   end

   local document = reply.status == 200 and identity_answers.document(reply.body) or nil
   local secret = json_body.text(document, "twoFactorSecret", 256)
   local qr_code_url = json_body.text(document, "qrCodeUrl", 2048)
   if secret == nil or qr_code_url == nil then
      return not_understood(request, reply, "setup")
   end

   respond.json(200, { twoFactorSecret = secret, qrCodeUrl = qr_code_url, enabled = false }, nil)
end

function sign_in.setup(request: RequestContext)
   local client = open(request)
   if client == nil then
      return
   end

   local value = sign_in.pending_cookie(request)
   local pending, failure = sessions.pending(client, request, value, "enrolment")
   if failure ~= nil then
      respond.error(failure, request.request_id, nil)
   elseif pending == nil or pending.user_id == nil or pending.user_id == 0 then
      no_pending(client, request, value)
   else
      settle_setup(client, request, identity_client.setup(request, pending.token, pending.user_id), value)
   end

   redis_store.release(client)
end

local function settle_enable(client: redis.Client, request: RequestContext, reply: UpstreamReply, value: string)
   if refused_by_identity(request, reply, "enable") or settle_enrolment_refusal(client, request, reply, value) then
      return
   end

   if reply.status == 422 then
      return respond.error("CODE_REFUSED", request.request_id, nil)
   end

   if reply.status == 400 then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   if reply.status ~= 200 then
      return not_understood(request, reply, "enable")
   end

   redis_store.delete(client, { sessions.pending_key_of(value) })
   respond.json(200, { enabled = true }, { cookies.expired(cookies.pending_name) })
end

function sign_in.enable(request: RequestContext)
   local code = code_of(request)
   if code == nil then
      return
   end

   local client = open(request)
   if client == nil then
      return
   end

   local value = sign_in.pending_cookie(request)
   local pending, failure = sessions.pending(client, request, value, "enrolment")
   if failure ~= nil then
      respond.error(failure, request.request_id, nil)
   elseif pending == nil or pending.user_id == nil or pending.user_id == 0 then
      no_pending(client, request, value)
   else
      settle_enable(client, request, identity_client.enable(request, pending.token, pending.user_id, code), value)
   end

   redis_store.release(client)
end

return sign_in
