local clock = require("adapters.clock")
local digest = require("adapters.digest")
local identity_answers = require("http.identity_answers")
local identity_client = require("adapters.identity_client")
local lifetimes = require("http.lifetimes")
local logger = require("adapters.logger")
local metrics = require("adapters.metrics")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local revocation = require("http.revocation")
local secure_random = require("adapters.secure_random")
local settings = require("http.settings")
local timing = require("config.timing")
local type AppName = require("types.app_name")
local type AppPolicy = require("types.app_policy")
local type EndReason = require("types.end_reason")
local type PendingKind = require("types.pending_kind")
local type PendingSignIn = require("types.pending_sign_in")
local type RefreshResult = require("types.refresh_result")
local type RequestContext = require("types.request_context")
local type Session = require("types.session")
local type SessionLookup = require("types.session_lookup")
local type SessionState = require("types.session_state")
local type TokenGrant = require("types.token_grant")

local record sessions
end

local SESSION_PREFIX = "edge:session:"
local PENDING_PREFIX = "edge:pending:"
local REFRESH_PREFIX = "edge:refresh:"

local FIELDS: {string} = {
   "access_token",
   "refresh_token",
   "access_expires_at",
   "app",
   "role",
   "principal_id",
   "created_at",
   "last_seen",
   "absolute_end",
}

local function integer_text(value: integer): string
   return string.format("%d", value)
end

local function integer_of(text: string): integer
   if text == nil or string.match(text, "^%d+$") == nil then
      return nil
   end

   return math.floor(tonumber(text))
end

local function app_name_of(text: string): AppName
   if text == "backoffice" or text == "seller-web" then
      return text as AppName
   end

   return nil
end

function sessions.open(): redis.Client
   local client, failure = redis_store.open(settings.current.environment)
   if client == nil then
      metrics.dependency_failed("redis")
      logger.warn("redis_unavailable", { cause = failure or "", request_id = ngx.var.edge_request_id or "" })
   end

   return client
end

function sessions.key_of(value: string): string
   return SESSION_PREFIX .. digest.sha256_hex(value)
end

function sessions.pending_key_of(value: string): string
   return PENDING_PREFIX .. digest.sha256_hex(value)
end

function sessions.tag_of(value: string): string
   if value == nil then
      return ""
   end

   return string.sub(digest.sha256_hex(value), 1, 8)
end

function sessions.admits(app: AppPolicy, role: string): boolean
   for _, admitted in ipairs(app.roles) do
      if admitted == role then
         return true
      end
   end

   return false
end

local function fields_of(session: Session): redis_store.Fields
   return {
      access_token = session.access_token,
      refresh_token = session.refresh_token,
      access_expires_at = integer_text(session.access_expires_at),
      app = session.app,
      role = session.role,
      principal_id = session.principal_id,
      created_at = integer_text(session.created_at),
      last_seen = integer_text(session.last_seen),
      absolute_end = integer_text(session.absolute_end),
   }
end

local function session_of(fields: redis_store.Fields): Session
   for _, name in ipairs(FIELDS) do
      if fields[name] == nil or fields[name] == "" then
         return nil
      end
   end

   local session: Session = {
      access_token = fields["access_token"],
      refresh_token = fields["refresh_token"],
      access_expires_at = integer_of(fields["access_expires_at"]),
      app = app_name_of(fields["app"]),
      role = fields["role"],
      principal_id = fields["principal_id"],
      created_at = integer_of(fields["created_at"]),
      last_seen = integer_of(fields["last_seen"]),
      absolute_end = integer_of(fields["absolute_end"]),
   }
   if session.access_expires_at == nil
      or session.app == nil
      or session.created_at == nil
      or session.last_seen == nil
      or session.absolute_end == nil then
      return nil
   end

   return session
end

local function ended_at_absolute(
   client: redis.Client,
   request: RequestContext,
   key: string,
   session: Session
): SessionLookup
   redis_store.delete(client, { key })
   metrics.session_ended(request.app.name, "absolute_limit")
   revocation.schedule(request, session, "absolute_limit")

   return { state = "ended", key = key, session = session }
end

function sessions.lookup(client: redis.Client, request: RequestContext, value: string): SessionLookup
   if value == nil then
      return { state = "absent" }
   end

   local key = sessions.key_of(value)
   local fields = redis_store.read_hash(client, key)
   if fields == nil then
      metrics.dependency_failed("redis")
      return { state = "unavailable", key = key }
   end

   local session = session_of(fields)
   if session == nil then
      if next(fields) ~= nil then
         redis_store.delete(client, { key })
      end

      metrics.session_ended(request.app.name, "unknown")
      return { state = "absent", key = key }
   end

   if session.app ~= request.app.name then
      return { state = "absent", key = key }
   end

   if lifetimes.is_past_absolute(session, clock.now_ms()) then
      return ended_at_absolute(client, request, key, session)
   end

   return { state = "found", key = key, session = session }
end

function sessions.touch(client: redis.Client, request: RequestContext, found: SessionLookup): SessionState
   local now = clock.now_ms()
   local ttl = lifetimes.idle_ttl_ms(request.app, found.session.absolute_end, now)
   if ttl <= 0 then
      return ended_at_absolute(client, request, found.key, found.session).state
   end

   found.session.last_seen = now

   local written = redis_store.write_hash(client, found.key, { last_seen = integer_text(now) }, ttl, {})
   if not written then
      metrics.dependency_failed("redis")
      return "unavailable"
   end

   return "found"
end

function sessions.begin(
   client: redis.Client,
   request: RequestContext,
   grant: TokenGrant,
   previous_session: string,
   previous_pending: string
): string, Session, string
   local value = secure_random.session_value()
   if value == nil then
      return nil, nil, "INTERNAL_ERROR"
   end

   local now = clock.now_ms()
   local session: Session = {
      access_token = grant.access_token,
      refresh_token = grant.refresh_token,
      access_expires_at = now + grant.expires_in * 1000,
      app = request.app.name,
      role = grant.role,
      principal_id = grant.principal_id,
      created_at = now,
      last_seen = now,
      absolute_end = lifetimes.absolute_end(request.app, now),
   }

   local removed: {string} = {}
   local replaced = false
   local previous: Session = nil
   if previous_session ~= nil then
      local previous_key = sessions.key_of(previous_session)
      local previous_fields = redis_store.read_hash(client, previous_key)
      if previous_fields == nil then
         metrics.dependency_failed("redis")
         return nil, nil, "SESSION_STORE_UNAVAILABLE"
      end

      replaced = next(previous_fields) ~= nil
      previous = session_of(previous_fields)
      table.insert(removed, previous_key)
   end

   if previous_pending ~= nil then
      table.insert(removed, sessions.pending_key_of(previous_pending))
   end

   local written = redis_store.write_hash(
      client,
      sessions.key_of(value),
      fields_of(session),
      lifetimes.idle_ttl_ms(request.app, session.absolute_end, now),
      removed
   )
   if not written then
      metrics.dependency_failed("redis")
      return nil, nil, "SESSION_STORE_UNAVAILABLE"
   end

   if replaced then
      metrics.session_ended(request.app.name, "replaced")
   end

   if previous ~= nil and previous.app == request.app.name then
      revocation.schedule(request, previous, "replaced")
   end

   metrics.session_started(request.app.name)

   return value, session, nil
end

function sessions.finish(client: redis.Client, request: RequestContext, keys: {string}, reason: EndReason): boolean
   local deleted = redis_store.delete(client, keys)
   if not deleted then
      metrics.dependency_failed("redis")
      return false
   end

   metrics.session_ended(request.app.name, reason)

   return true
end

function sessions.begin_pending(
   client: redis.Client,
   request: RequestContext,
   kind: PendingKind,
   token: string,
   user_id: integer,
   expires_in: integer,
   previous_pending: string
): string, integer, string
   local value = secure_random.session_value()
   if value == nil then
      return nil, nil, "INTERNAL_ERROR"
   end

   local lifetime = expires_in
   if lifetime > timing.pending_max_seconds then
      lifetime = timing.pending_max_seconds
   end

   local fields: redis_store.Fields = {
      kind = kind,
      token = token,
      app = request.app.name,
      user_id = integer_text(user_id or 0),
   }
   local removed: {string} = {}
   if previous_pending ~= nil then
      table.insert(removed, sessions.pending_key_of(previous_pending))
   end

   local written = redis_store.write_hash(client, sessions.pending_key_of(value), fields, lifetime * 1000, removed)
   if not written then
      metrics.dependency_failed("redis")
      return nil, nil, "SESSION_STORE_UNAVAILABLE"
   end

   return value, lifetime, nil
end

function sessions.pending(
   client: redis.Client,
   request: RequestContext,
   value: string,
   kind: PendingKind
): PendingSignIn, string
   if value == nil then
      return nil, nil
   end

   local fields = redis_store.read_hash(client, sessions.pending_key_of(value))
   if fields == nil then
      metrics.dependency_failed("redis")
      return nil, "SESSION_STORE_UNAVAILABLE"
   end

   if fields["kind"] ~= kind or fields["app"] ~= request.app.name or fields["token"] == nil then
      return nil, nil
   end

   return { kind = kind, token = fields["token"], app = request.app.name, user_id = integer_of(fields["user_id"]) }, nil
end

local function release_lock(client: redis.Client, lock_key: string, owner: string)
   local holder = redis_store.read(client, lock_key)
   if holder == owner then
      redis_store.delete(client, { lock_key })
   end
end

function sessions.log_out_quietly(request: RequestContext, grant: TokenGrant, stage: string)
   local reply = identity_client.logout(request, grant.access_token, grant.refresh_token)
   if not reply.reached or reply.status >= 300 then
      metrics.dependency_failed("identity")
      logger.warn(
         "identity_logout_failed",
         { stage = stage, status = reply.status or 0, cause = reply.cause or "", request_id = request.request_id }
      )
   end
end

local function renew(client: redis.Client, request: RequestContext, found: SessionLookup): RefreshResult
   local fields = redis_store.read_hash(client, found.key)
   if fields == nil then
      metrics.dependency_failed("redis")
      return { outcome = "store_unavailable" }
   end

   local current = session_of(fields)
   if current == nil then
      return { outcome = "refused" }
   end

   if not lifetimes.needs_refresh(current, clock.now_ms(), timing.refresh_before_ms) then
      return { outcome = "renewed", session = current }
   end

   local reply = identity_client.refresh(request, current.refresh_token)
   local document = identity_answers.document(reply.body)
   local code = identity_answers.error_code(document)
   if not reply.reached
      or reply.status >= 500
      or reply.status == 429
      or identity_answers.is_client_refusal(code) then
      metrics.refresh(request.app.name, "unavailable")
      if not reply.reached or reply.status >= 500 then
         metrics.dependency_failed("identity")
      end

      logger.warn(
         "refresh_unavailable",
         { status = reply.status or 0, error = code or "", cause = reply.cause or "", request_id = request.request_id }
      )
      return { outcome = "unavailable" }
   end

   local grant = reply.status == 200 and identity_answers.grant(document) or nil
   if reply.status == 200 and grant == nil then
      logger.error("refresh_answer_malformed", { request_id = request.request_id })
   end

   if grant == nil then
      redis_store.delete(client, { found.key })
      metrics.refresh(request.app.name, "refused")
      metrics.session_ended(request.app.name, "refresh_refused")
      logger.info("refresh_refused", { status = reply.status, error = code or "", request_id = request.request_id })
      return { outcome = "refused" }
   end

   if not sessions.admits(request.app, grant.role) then
      redis_store.delete(client, { found.key })
      sessions.log_out_quietly(request, grant, "refresh")
      metrics.refresh(request.app.name, "role_refused")
      metrics.session_ended(request.app.name, "role_refused")
      logger.info("role_refused", { stage = "refresh", role = grant.role, request_id = request.request_id })
      return { outcome = "role_refused" }
   end

   local now = clock.now_ms()
   current.access_token = grant.access_token
   current.refresh_token = grant.refresh_token
   current.access_expires_at = now + grant.expires_in * 1000
   current.role = grant.role
   current.principal_id = grant.principal_id

   local written = redis_store.write_hash(
      client,
      found.key,
      {
         access_token = current.access_token,
         refresh_token = current.refresh_token,
         access_expires_at = integer_text(current.access_expires_at),
         role = current.role,
         principal_id = current.principal_id,
      },
      lifetimes.idle_ttl_ms(request.app, current.absolute_end, now),
      {}
   )
   if not written then
      metrics.dependency_failed("redis")
      logger.error("refresh_not_stored", { request_id = request.request_id })
      return { outcome = "store_unavailable" }
   end

   metrics.refresh(request.app.name, "renewed")

   return { outcome = "renewed", session = current }
end

local function wait_for(client: redis.Client, found: SessionLookup, lock_key: string): RefreshResult
   local deadline = clock.now_ms() + timing.refresh_wait_ms
   while clock.now_ms() < deadline do
      ngx.sleep(timing.refresh_poll_seconds)

      local holder, failure = redis_store.read(client, lock_key)
      if failure ~= nil then
         metrics.dependency_failed("redis")
         return { outcome = "store_unavailable" }
      end

      if holder == nil then
         local fields = redis_store.read_hash(client, found.key)
         if fields == nil then
            metrics.dependency_failed("redis")
            return { outcome = "store_unavailable" }
         end

         local current = session_of(fields)
         if current == nil then
            return { outcome = "refused" }
         end

         if lifetimes.needs_refresh(current, clock.now_ms(), timing.refresh_before_ms) then
            return { outcome = "unavailable" }
         end

         return { outcome = "renewed", session = current }
      end
   end

   return { outcome = "unavailable" }
end

function sessions.refresh(client: redis.Client, request: RequestContext, found: SessionLookup): RefreshResult
   local lock_key = REFRESH_PREFIX .. string.sub(found.key, #SESSION_PREFIX + 1)
   local owner = secure_random.hex(16)
   if owner == nil then
      return { outcome = "unavailable" }
   end

   local claimed, failure = redis_store.claim(client, lock_key, owner, timing.refresh_lock_ms)
   if failure ~= nil then
      metrics.dependency_failed("redis")
      return { outcome = "store_unavailable" }
   end

   if not claimed then
      return wait_for(client, found, lock_key)
   end

   local result = renew(client, request, found)
   release_lock(client, lock_key, owner)

   return result
end

function sessions.needs_refresh(session: Session): boolean
   return lifetimes.needs_refresh(session, clock.now_ms(), timing.refresh_before_ms)
end

return sessions
