local cjson = require("cjson.safe")
local type FakeSettings = require("tests.integration.fakes.types.fake_settings")
local type FakeToken = require("tests.integration.fakes.types.fake_token")
local type FakeUser = require("tests.integration.fakes.types.fake_user")

local record identity
end

local CODE = "123456"
local CLIENTS: {string: boolean} = { ["backoffice"] = true, ["seller-web"] = true }

local users: {string: FakeUser} = {}
local tokens: {string: FakeToken} = {}
local counters: {string: integer} = {}
local last_headers: {string: {string: string}} = {}
local last_paths: {string: string} = {}
local issued: {string: string} = {}
local buckets: {string: integer} = {}
local sequence = 0
local settings: FakeSettings = nil

local function seed()
   users = {}
   tokens = {}
   counters = {}
   last_headers = {}
   last_paths = {}
   issued = {}
   buckets = {}
   settings = {
      refresh_mode = "ok",
      refresh_delay_ms = 0,
      login_mode = "ok",
      logout_mode = "ok",
      access_expires_in = 900,
      roles = {},
   }

   local rows: {{string}} = {
      { "seller@example.test", "seller", "false" },
      { "seller-2fa@example.test", "seller", "true" },
      { "customer@example.test", "customer", "false" },
      { "courier@example.test", "courier", "false" },
      { "admin-2fa@example.test", "admin", "true" },
      { "admin-new@example.test", "admin", "false" },
   }
   for index, row in ipairs(rows) do
      users[row[1]] = {
         id = 100 + index,
         email = row[1],
         password = "correct-password",
         role = row[2],
         principal_id = "prn_fake_" .. string.format("%d", 100 + index),
         two_factor = row[3] == "true",
         secret_issued = false,
      }
   end
end

seed()

local function next_token(kind: string, email: string, family: string, client: string): string
   sequence = sequence + 1
   local value = "fake-" .. kind .. "-" .. string.format("%d", sequence)
   tokens[value] = { kind = kind, email = email, family = family, client = client, spent = false, revoked = false }
   issued[kind] = value

   return value
end

local function count(name: string)
   counters[name] = (counters[name] or 0) + 1
end

local function remember(name: string)
   local headers = ngx.req.get_headers(100, false)
   local flat: {string: string} = {}
   for key, value in pairs(headers) do
      if value is string then
         flat[key] = value
      else
         flat[key] = table.concat(value, ", ")
      end
   end

   last_headers[name] = flat
   last_paths[name] = ngx.var.uri
end

local function answer<T>(status: integer, value: T)
   ngx.status = status
   ngx.header["Content-Type"] = "application/json"
   local text = cjson.encode(value)
   ngx.print(text)
end

local function refuse(status: integer, error_name: string, message: string)
   answer(
      status,
      { statusCode = status, error = error_name, message = message, traceId = ngx.var.http_x_request_id or "-" }
   )
end

local function body(): cjson.Document
   ngx.req.read_body()

   local decoded = cjson.decode(ngx.req.get_body_data() or "")
   if decoded is cjson.Document then
      return decoded
   end

   return {}
end

local function text(document: cjson.Document, name: string): string
   local value = document[name]
   if value is string then
      return value
   end

   return nil
end

local function bearer(): string
   local header = ngx.var.http_authorization
   if header == nil then
      return nil
   end

   return string.match(header, "^Bearer (.+)$")
end

local function role_of(user: FakeUser): string
   return settings.roles[user.email] or user.role
end

local function pair(user: FakeUser, family: string, client: string)
   answer(
      200,
      {
         accessToken = next_token("access", user.email, family, client),
         refreshToken = next_token("refresh", user.email, family, client),
         expiresIn = settings.access_expires_in,
         tokenType = "Bearer",
         user = { id = user.id, email = user.email, role = role_of(user), principalId = user.principal_id },
      }
   )
end

local function client_refused(): boolean
   local client = ngx.var.http_x_kinetix_client
   if client == nil or not CLIENTS[client] then
      refuse(400, "UNKNOWN_CLIENT", "X-Kinetix-Client names a client identity does not know.")
      return true
   end

   return false
end

local function login()
   count("login")
   remember("login")

   if settings.login_mode == "close" then
      return ngx.exit(444)
   end

   if settings.login_mode == "unavailable" then
      return refuse(503, "DATABASE_UNAVAILABLE", "identity could not reach its database.")
   end

   if client_refused() then
      return
   end

   local document = body()
   local email = text(document, "email")
   if email == "delayed@example.test" then
      ngx.header["Retry-After"] = "7"
      return answer(
         429,
         {
            error = "SIGN_IN_DELAYED",
            message = "Too many unsuccessful sign-in attempts for this account.",
            retryAfterSeconds = 7,
            traceId = "-",
         }
      )
   end

   local user = users[email or ""]
   if user == nil or text(document, "password") ~= user.password then
      return refuse(401, "Unauthorized", "Invalid email or password credentials")
   end

   if user.two_factor then
      return answer(
         200,
         { mfaRequired = true, challengeToken = next_token("challenge", user.email, "", ""), expiresIn = 300 }
      )
   end

   if user.role == "admin" then
      return answer(
         200,
         {
            mfaEnrolmentRequired = true,
            enrolmentToken = next_token("enrolment", user.email, "", ngx.var.http_x_kinetix_client),
            tokenType = "Bearer",
            expiresIn = 600,
            userId = user.id,
         }
      )
   end

   sequence = sequence + 1
   pair(user, "family-" .. string.format("%d", sequence), ngx.var.http_x_kinetix_client)
end

local function verify()
   count("verify")
   remember("verify")

   if client_refused() then
      return
   end

   local document = body()
   local token = tokens[text(document, "challengeToken") or ""]
   if token == nil or token.kind ~= "challenge" or token.spent then
      return refuse(401, "Unauthorized", "This is not a two-factor challenge")
   end

   if text(document, "code") ~= CODE then
      return refuse(401, "Unauthorized", "That code is not valid")
   end

   token.spent = true
   sequence = sequence + 1
   pair(users[token.email], "family-" .. string.format("%d", sequence), ngx.var.http_x_kinetix_client)
end

local function enrolment_user(): FakeUser
   local token = tokens[bearer() or ""]
   if token == nil or token.kind ~= "enrolment" or token.revoked then
      refuse(401, "Unauthorized", "Invalid token")
      return nil
   end

   local user = users[token.email]
   local id = tonumber(string.match(ngx.var.uri, "/(%d+)$"))
   if id ~= user.id then
      refuse(403, "Forbidden", "This account may only act on its own second factor")
      return nil
   end

   return user
end

local function issue_secret()
   count("setup")
   remember("setup")

   local user = enrolment_user()
   if user == nil then
      return
   end

   if user.two_factor then
      return refuse(409, "Conflict", "Two-factor authentication is already enabled for this account")
   end

   user.secret_issued = true
   answer(
      200,
      {
         twoFactorSecret = "JBSWY3DPEHPK3PXP",
         qrCodeUrl = "otpauth://totp/Kinetix:" .. user.email .. "?secret=JBSWY3DPEHPK3PXP&issuer=Kinetix",
         enabled = false,
      }
   )
end

local function enable()
   count("enable")
   remember("enable")

   local user = enrolment_user()
   if user == nil then
      return
   end

   local document = body()
   if not user.secret_issued then
      return refuse(400, "Bad Request", "Request a two-factor secret before enabling it")
   end

   if text(document, "code") ~= CODE then
      return refuse(422, "Unprocessable Entity", "That code is not valid")
   end

   user.two_factor = true
   tokens[bearer()].revoked = true
   answer(200, { enabled = true })
end

local function revoke_family(family: string)
   for _, token in pairs(tokens) do
      if token.family == family then
         token.revoked = true
      end
   end
end

local function refresh()
   count("refresh")
   remember("refresh")

   if settings.refresh_delay_ms > 0 then
      ngx.sleep(settings.refresh_delay_ms / 1000)
   end

   if settings.refresh_mode == "close" then
      return ngx.exit(444)
   end

   if settings.refresh_mode == "unavailable" then
      return refuse(503, "DATABASE_UNAVAILABLE", "identity could not reach its database.")
   end

   if settings.refresh_mode == "unknown_client" then
      return refuse(400, "UNKNOWN_CLIENT", "X-Kinetix-Client names a client identity does not know.")
   end

   if settings.refresh_mode == "refuse" then
      return refuse(401, "TWO_FACTOR_REQUIRED", "An admin account must use two-factor authentication.")
   end

   if client_refused() then
      return
   end

   local presented = text(body(), "refreshToken") or ""
   local token = tokens[presented]
   if token == nil or token.kind ~= "refresh" or token.revoked then
      return refuse(401, "Unauthorized", "This is not a refresh token")
   end

   if token.client ~= ngx.var.http_x_kinetix_client then
      return refuse(401, "CLIENT_MISMATCH", "This session was started by another client.")
   end

   if token.spent then
      count("reuse")
      revoke_family(token.family)
      return refuse(401, "Unauthorized", "This refresh token was already used")
   end

   token.spent = true
   pair(users[token.email], token.family, token.client)
end

local function logout()
   count("logout")
   remember("logout")

   if settings.logout_mode == "close" then
      return ngx.exit(444)
   end

   if settings.logout_mode == "unavailable" then
      return refuse(503, "DATABASE_UNAVAILABLE", "identity could not reach its database.")
   end

   local access = tokens[bearer() or ""]
   if access == nil or access.kind ~= "access" or access.revoked then
      return refuse(401, "Unauthorized", "A Bearer token is required")
   end

   local presented = text(body(), "refreshToken")
   issued["logged_out_refresh"] = presented
   if presented ~= nil then
      local refresh_token = tokens[presented]
      if refresh_token == nil or refresh_token.email ~= access.email then
         return refuse(403, "Forbidden", "That refresh token belongs to another account")
      end
   end

   access.revoked = true
   revoke_family(access.family)
   ngx.status = 204
end

local ME_LIMIT = 3

local function me()
   count("me")
   remember("me")

   local address = string.match(ngx.var.http_x_forwarded_for or "", "([^,%s]+)%s*$") or "-"
   buckets[address] = (buckets[address] or 0) + 1
   if buckets[address] > ME_LIMIT then
      ngx.header["Retry-After"] = "60"
      return refuse(429, "REQUEST_REFUSED", "ThrottlerException: Too Many Requests")
   end

   local access = tokens[bearer() or ""]
   if access == nil or access.kind ~= "access" or access.revoked then
      return refuse(401, "Unauthorized", "A Bearer token is required")
   end

   local user = users[access.email]
   ngx.header["Set-Cookie"] = "identity=1; Path=/"
   answer(
      200,
      { principalId = user.principal_id, userId = user.id, email = user.email, role = role_of(user) }
   )
end

local function couriers()
   count("couriers")
   remember("couriers")
   answer(200, { applications = 0, path = ngx.var.uri })
end

local function family_revoked(family: string): boolean
   for _, token in pairs(tokens) do
      if token.family == family and token.kind == "refresh" and token.revoked then
         return true
      end
   end

   return false
end

local function state()
   local revoked: {string: boolean} = {}
   for value, token in pairs(tokens) do
      if token.kind == "refresh" then
         revoked[value] = family_revoked(token.family)
      end
   end

   answer(200, { counters = counters, headers = last_headers, paths = last_paths, issued = issued, revoked = revoked })
end

local function configure()
   local document = body()
   local mode = text(document, "refresh_mode")
   if mode ~= nil then
      settings.refresh_mode = mode
   end

   local login_mode = text(document, "login_mode")
   if login_mode ~= nil then
      settings.login_mode = login_mode
   end

   local logout_mode = text(document, "logout_mode")
   if logout_mode ~= nil then
      settings.logout_mode = logout_mode
   end

   local delay = document["refresh_delay_ms"]
   if delay is number then
      settings.refresh_delay_ms = math.floor(delay)
   end

   local expires_in = document["access_expires_in"]
   if expires_in is number then
      settings.access_expires_in = math.floor(expires_in)
   end

   local roles = document["roles"]
   if roles is cjson.Object then
      for email, role in pairs(roles) do
         if role is string then
            settings.roles[email] = role
         end
      end
   end

   answer(200, { configured = true })
end

local ROUTES: {string: function()} = {
   ["/api/v1/auth/login"] = login,
   ["/api/v1/auth/2fa/verify"] = verify,
   ["/api/v1/auth/refresh"] = refresh,
   ["/api/v1/auth/logout"] = logout,
   ["/api/v1/auth/me"] = me,
   ["/__fake/state"] = state,
   ["/__fake/settings"] = configure,
}

function identity.serve()
   local uri = ngx.var.uri
   if uri == "/__fake/reset" then
      seed()
      return answer(200, { reset = true })
   end

   if string.match(uri, "^/api/v1/auth/2fa/setup/%d+$") ~= nil then
      return issue_secret()
   end

   if string.match(uri, "^/api/v1/auth/2fa/enable/%d+$") ~= nil then
      return enable()
   end

   if string.match(uri, "^/api/v1/couriers/") ~= nil then
      return couriers()
   end

   local route = ROUTES[uri]
   if route == nil then
      return refuse(404, "Not Found", "Cannot " .. ngx.req.get_method() .. " " .. uri)
   end

   route()
end

return identity
