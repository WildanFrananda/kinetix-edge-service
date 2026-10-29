local cjson = require("cjson.safe")
local passkey_fixture = require("tests.integration.fakes.passkey_fixture")
local type FakeSettings = require("tests.integration.fakes.types.fake_settings")
local type FakeToken = require("tests.integration.fakes.types.fake_token")
local type FakeUser = require("tests.integration.fakes.types.fake_user")

local record identity
end

local CODE = "123456"
local CHALLENGE_ATTEMPTS = 5
local CLIENTS: {string: boolean} = { ["backoffice"] = true, ["seller-web"] = true }

local users: {string: FakeUser} = {}
local tokens: {string: FakeToken} = {}
local counters: {string: integer} = {}
local last_headers: {string: {string: string}} = {}
local last_paths: {string: string} = {}
local last_methods: {string: string} = {}
local last_bodies: {string: string} = {}
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
   last_methods = {}
   last_bodies = {}
   issued = {}
   buckets = {}
   settings = {
      refresh_mode = "ok",
      refresh_delay_ms = 0,
      login_mode = "ok",
      logout_mode = "ok",
      register_mode = "ok",
      verify_codes = "on",
      passkeys_flag = "on",
      passkey_mode = "ok",
      access_expires_in = 900,
      roles = {},
   }

   local rows: {{string}} = {
      { "seller@example.test", "seller", "false", "false" },
      { "seller-2fa@example.test", "seller", "true", "false" },
      { "customer@example.test", "customer", "false", "false" },
      { "courier@example.test", "courier", "false", "false" },
      { "admin-2fa@example.test", "admin", "true", "false" },
      { "admin-new@example.test", "admin", "false", "false" },
      { "admin-passkey@example.test", "admin", "true", "true" },
      { "seller-passkey@example.test", "seller", "true", "true" },
   }
   for index, row in ipairs(rows) do
      users[row[1]] = {
         id = 100 + index,
         email = row[1],
         password = "correct-password",
         role = row[2],
         principal_id = "prn_fake_" .. string.format("%d", 100 + index),
         two_factor = row[3] == "true",
         passkeys = row[4] == "true",
         secret_issued = false,
      }
   end
end

seed()

local function next_token(kind: string, email: string, family: string, client: string): string
   sequence = sequence + 1
   local value = "fake-" .. kind .. "-" .. string.format("%d", sequence)
   tokens[value] = {
      kind = kind,
      email = email,
      family = family,
      client = client,
      spent = false,
      revoked = false,
      attempts = 0,
   }
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

   ngx.req.read_body()

   last_headers[name] = flat
   last_paths[name] = ngx.var.uri
   last_methods[name] = ngx.req.get_method()
   last_bodies[name] = ngx.req.get_body_data() or ""
end

local function answer<T>(status: integer, value: T)
   ngx.status = status
   ngx.header["Content-Type"] = "application/json"
   local text = cjson.encode(value)
   ngx.print(text)
end

local function raw(status: integer, text: string)
   ngx.status = status
   ngx.header["Content-Type"] = "application/json"
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

local function pair(user: FakeUser, family: string, client: string, status: integer)
   answer(
      status,
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
      local challenge = next_token("challenge", user.email, "", "")
      if settings.passkeys_flag == "off" then
         return answer(200, { mfaRequired = true, challengeToken = challenge, expiresIn = 300 })
      end

      return answer(
         200,
         { mfaRequired = true, challengeToken = challenge, expiresIn = 300, passkeys = user.passkeys }
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
   pair(user, "family-" .. string.format("%d", sequence), ngx.var.http_x_kinetix_client, 200)
end

local function challenge_refused(code: string, message: string)
   if settings.verify_codes == "off" then
      return refuse(401, "Unauthorized", message)
   end

   answer(401, { error = code, message = message, traceId = ngx.var.http_x_request_id or "-" })
end

local function open_challenge(document: cjson.Document): FakeToken
   local token = tokens[text(document, "challengeToken") or ""]
   if token == nil or token.kind ~= "challenge" then
      challenge_refused("CHALLENGE_INVALID", "This is not a two-factor challenge")
      return nil
   end

   if token.spent then
      challenge_refused("CHALLENGE_SPENT", "This two-factor challenge was already used")
      return nil
   end

   if token.attempts >= CHALLENGE_ATTEMPTS then
      challenge_refused("CHALLENGE_EXHAUSTED", "Too many wrong codes for this challenge. Sign in again")
      return nil
   end

   return token
end

local function verify()
   count("verify")
   remember("verify")

   if client_refused() then
      return
   end

   local document = body()
   local token = open_challenge(document)
   if token == nil then
      return
   end

   if text(document, "code") ~= CODE then
      token.attempts = token.attempts + 1
      return challenge_refused("WRONG_CODE", "That code is not valid")
   end

   token.spent = true
   sequence = sequence + 1
   pair(users[token.email], "family-" .. string.format("%d", sequence), ngx.var.http_x_kinetix_client, 200)
end

local function passkey_unavailable(): boolean
   if settings.passkey_mode == "close" then
      ngx.exit(444)
      return true
   end

   if settings.passkey_mode == "unavailable" then
      refuse(503, "DATABASE_UNAVAILABLE", "identity could not reach its database.")
      return true
   end

   return client_refused()
end

local function passkey_options()
   count("passkey_options")
   remember("passkey_options")

   if passkey_unavailable() then
      return
   end

   local token = open_challenge(body())
   if token == nil then
      return
   end

   if settings.passkey_mode == "malformed" then
      return raw(200, "{\"options\":[]}")
   end

   if not users[token.email].passkeys then
      return answer(
         409,
         {
            error = "NO_PASSKEYS",
            message = "This account has no passkey; answer the challenge with the code.",
            traceId = ngx.var.http_x_request_id or "-",
         }
      )
   end

   sequence = sequence + 1
   token.passkey_challenge = "fake-passkey-challenge-" .. string.format("%d", sequence)
   issued["passkey_challenge"] = token.passkey_challenge
   raw(200, passkey_fixture.options(token.passkey_challenge))
end

local function passkey_verify()
   count("passkey_verify")
   remember("passkey_verify")

   if passkey_unavailable() then
      return
   end

   local document = body()
   local token = open_challenge(document)
   if token == nil then
      return
   end

   local user = users[token.email]
   local credential = document["credential"]
   if token.passkey_challenge == nil
      or not user.passkeys
      or not credential is cjson.Object
      or credential["id"] ~= passkey_fixture.credential_id then
      token.attempts = token.attempts + 1
      return challenge_refused("PASSKEY_REFUSED", "The passkey was not accepted")
   end

   token.spent = true
   sequence = sequence + 1
   pair(user, "family-" .. string.format("%d", sequence), ngx.var.http_x_kinetix_client, 200)
end

local function registration_refusal(email: string, password: string): {string}
   local problems: {string} = {}
   if email == nil or string.find(email, "@", 1, true) == nil then
      table.insert(problems, "email must be an email")
   end

   if password == nil or #password < 12 then
      table.insert(problems, "password must be longer than or equal to 12 characters")
   elseif #password > 72 then
      table.insert(problems, "password must be at most 72 bytes, which is all bcrypt reads")
   end

   return problems
end

local function register()
   count("register")
   remember("register")

   if settings.register_mode == "close" then
      return ngx.exit(444)
   end

   if settings.register_mode == "unavailable" then
      return refuse(503, "DATABASE_UNAVAILABLE", "identity could not reach its database.")
   end

   if client_refused() then
      return
   end

   local document = body()
   local email = text(document, "email")
   local password = text(document, "password")
   if email == "throttled@example.test" then
      ngx.header["Retry-After"] = "60"
      return refuse(429, "REQUEST_REFUSED", "ThrottlerException: Too Many Requests")
   end

   local problems = registration_refusal(email, password)
   if #problems > 0 then
      return answer(
         400,
         { statusCode = 400, message = problems, error = "Bad Request", traceId = ngx.var.http_x_request_id or "-" }
      )
   end

   if users[email] ~= nil then
      return refuse(409, "Conflict", "Email address is already registered")
   end

   sequence = sequence + 1
   local user: FakeUser = {
      id = 200 + sequence,
      email = email,
      password = password,
      role = "customer",
      principal_id = "prn_fake_" .. string.format("%d", 200 + sequence),
      two_factor = false,
      secret_issued = false,
   }
   users[email] = user
   pair(user, "family-" .. string.format("%d", sequence), ngx.var.http_x_kinetix_client, 201)
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
   pair(users[token.email], token.family, token.client, 200)
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

local function passkeys()
   count("passkeys")
   remember("passkeys")

   local access = tokens[bearer() or ""]
   if access == nil or access.kind ~= "access" or access.revoked then
      return refuse(401, "Unauthorized", "A Bearer token is required")
   end

   local method = ngx.req.get_method()
   if method == "DELETE" then
      ngx.status = 204
      return
   end

   if method == "GET" then
      return raw(200, "{\"passkeys\":[" .. passkey_fixture.created .. "]}")
   end

   if string.match(ngx.var.uri, "/options$") ~= nil then
      return raw(200, passkey_fixture.creation_options)
   end

   raw(201, passkey_fixture.created)
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

   answer(
      200,
      {
         counters = counters,
         headers = last_headers,
         paths = last_paths,
         methods = last_methods,
         bodies = last_bodies,
         issued = issued,
         revoked = revoked,
      }
   )
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

   local register_mode = text(document, "register_mode")
   if register_mode ~= nil then
      settings.register_mode = register_mode
   end

   local verify_codes = text(document, "verify_codes")
   if verify_codes ~= nil then
      settings.verify_codes = verify_codes
   end

   local passkeys_flag = text(document, "passkeys_flag")
   if passkeys_flag ~= nil then
      settings.passkeys_flag = passkeys_flag
   end

   local passkey_mode = text(document, "passkey_mode")
   if passkey_mode ~= nil then
      settings.passkey_mode = passkey_mode
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
   ["/api/v1/auth/register"] = register,
   ["/api/v1/auth/2fa/verify"] = verify,
   ["/api/v1/auth/2fa/passkey/options"] = passkey_options,
   ["/api/v1/auth/2fa/passkey/verify"] = passkey_verify,
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

   if string.match(uri, "^/api/v1/auth/passkeys/") ~= nil then
      return passkeys()
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
