local cjson = require("cjson.safe")
local http_client = require("adapters.http_client")
local json_relay = require("adapters.json_relay")
local settings = require("http.settings")
local timing = require("config.timing")
local type RequestContext = require("types.request_context")
local type UpstreamReply = require("types.upstream_reply")

local record identity_client
end

local TIMEOUTS: http_client.Timeouts = {
   connect_ms = timing.identity_connect_ms,
   send_ms = timing.identity_send_ms,
   read_ms = timing.identity_read_ms,
}

local function post(context: RequestContext, path: string, body: string, bearer: string): UpstreamReply
   local headers: {string: string} = {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/json",
      ["X-Kinetix-Client"] = context.app.client,
      ["X-Forwarded-For"] = context.client_address,
      ["X-Request-Id"] = context.request_id,
   }
   if bearer ~= nil then
      headers["Authorization"] = "Bearer " .. bearer
   end

   return http_client.request(
      settings.current.environment.identity_url .. path,
      { method = "POST", body = body, headers = headers },
      TIMEOUTS
   )
end

function identity_client.login(context: RequestContext, email: string, password: string): UpstreamReply
   local body = cjson.encode({ email = email, password = password })

   return post(context, "/api/v1/auth/login", body, nil)
end

function identity_client.register(context: RequestContext, email: string, password: string): UpstreamReply
   local body = cjson.encode({ email = email, password = password })

   return post(context, "/api/v1/auth/register", body, nil)
end

function identity_client.verify(context: RequestContext, challenge_token: string, code: string): UpstreamReply
   local body = cjson.encode({ challengeToken = challenge_token, code = code })

   return post(context, "/api/v1/auth/2fa/verify", body, nil)
end

function identity_client.passkey_options(context: RequestContext, challenge_token: string): UpstreamReply
   local body = cjson.encode({ challengeToken = challenge_token })

   return post(context, "/api/v1/auth/2fa/passkey/options", body, nil)
end

function identity_client.passkey_verify(
   context: RequestContext,
   challenge_token: string,
   credential: cjson.Object
): UpstreamReply
   local body = json_relay.encode({ challengeToken = challenge_token, credential = credential })

   return post(context, "/api/v1/auth/2fa/passkey/verify", body, nil)
end

function identity_client.setup(context: RequestContext, enrolment_token: string, user_id: integer): UpstreamReply
   return post(context, "/api/v1/auth/2fa/setup/" .. string.format("%d", user_id), "{}", enrolment_token)
end

function identity_client.enable(
   context: RequestContext,
   enrolment_token: string,
   user_id: integer,
   code: string
): UpstreamReply
   local body = cjson.encode({ code = code })

   return post(context, "/api/v1/auth/2fa/enable/" .. string.format("%d", user_id), body, enrolment_token)
end

function identity_client.refresh(context: RequestContext, refresh_token: string): UpstreamReply
   local body = cjson.encode({ refreshToken = refresh_token })

   return post(context, "/api/v1/auth/refresh", body, nil)
end

function identity_client.logout(context: RequestContext, access_token: string, refresh_token: string): UpstreamReply
   local body = cjson.encode({ refreshToken = refresh_token })

   return post(context, "/api/v1/auth/logout", body, access_token)
end

return identity_client
