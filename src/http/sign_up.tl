local errors = require("http.errors")
local identity_answers = require("http.identity_answers")
local identity_client = require("adapters.identity_client")
local json_body = require("http.json_body")
local redis = require("resty.redis")
local redis_store = require("adapters.redis_store")
local respond = require("http.respond")
local sign_in = require("http.sign_in")
local type EdgeError = require("types.edge_error")
local type RequestContext = require("types.request_context")
local type UpstreamReply = require("types.upstream_reply")

local record sign_up
end

local EMAIL_LONGEST = 254
local PASSWORD_LONGEST = 1024

local function invalid(request: RequestContext, reply: UpstreamReply)
   local catalogued = errors.catalogue["INVALID_REQUEST"]
   local relayed: EdgeError = {
      status = catalogued.status,
      code = catalogued.code,
      message = identity_answers.validation_message(identity_answers.document(reply.body)) or catalogued.message,
   }

   respond.edge_error(relayed, request.request_id, nil, nil)
end

local function settle(client: redis.Client, request: RequestContext, reply: UpstreamReply)
   if sign_in.refused_by_identity(request, reply, "register") then
      return
   end

   if reply.status == 409 then
      return respond.error("EMAIL_TAKEN", request.request_id, nil)
   end

   if reply.status == 400 then
      return invalid(request, reply)
   end

   local grant = reply.status == 201 and identity_answers.grant(identity_answers.document(reply.body)) or nil
   if grant == nil then
      return sign_in.not_understood(request, reply, "register")
   end

   sign_in.start_session(client, request, grant, "register", 201)
end

function sign_up.serve(request: RequestContext)
   local body = json_body.object()
   local email = json_body.text(body, "email", EMAIL_LONGEST)
   local password = json_body.text(body, "password", PASSWORD_LONGEST)
   if email == nil or password == nil then
      return respond.error("INVALID_REQUEST", request.request_id, nil)
   end

   local client = sign_in.open(request)
   if client == nil then
      return
   end

   settle(client, request, identity_client.register(request, email, password))
   redis_store.release(client)
end

return sign_up
