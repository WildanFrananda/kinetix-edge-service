local cjson = require("cjson.safe")
local check = require("tests.support.check")
local client = require("tests.support.client")
local digest = require("adapters.digest")
local fake = require("tests.support.fake")
local flows = require("tests.support.flows")
local json_relay = require("adapters.json_relay")
local passkey_fixture = require("tests.integration.fakes.passkey_fixture")
local redis_admin = require("tests.support.redis_admin")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")

local ATTRIBUTES = "; Path=/; Secure; HttpOnly; SameSite=Strict"
local EXPIRED_PENDING = "__Host-kx_pending=" .. ATTRIBUTES .. "; Max-Age=0"

local function members(value: cjson.Object): {string: cjson.Field}
   return value as {string: cjson.Field}
end

local function same(left: cjson.Field, right: cjson.Field): boolean
   if left is cjson.Object and right is cjson.Object then
      if getmetatable(left) ~= getmetatable(right) then
         return false
      end

      for key, value in pairs(members(left)) do
         if not same(value, members(right)[key]) then
            return false
         end
      end

      for key in pairs(members(right)) do
         if members(left)[key] == nil then
            return false
         end
      end

      return true
   end

   return left == right
end

local function names(document: cjson.Document): string
   local found: {string} = {}
   if document ~= nil then
      for name in pairs(document) do
         table.insert(found, name)
      end
   end

   table.sort(found)

   return table.concat(found, ",")
end

local function pending_of(app: string, email: string): string
   local value = client.cookie_value(flows.login(app, email, nil), "__Host-kx_pending")
   check.present(value, "pending cookie of " .. email)

   return value
end

local function cookie_of(pending: string): string
   if pending == nil then
      return nil
   end

   return flows.pending(pending)
end

local function options(app: string, pending: string): Answer
   return client.edge("POST", "/bff/2fa/passkey/options", { app = app, cookie = cookie_of(pending) })
end

local function verify(app: string, pending: string, body: string): Answer
   return client.edge("POST", "/bff/2fa/passkey/verify", { app = app, cookie = cookie_of(pending), body = body })
end

local function credential_body(id: string): string
   return "{\"credential\":" .. passkey_fixture.credential(id) .. "}"
end

local function refused(answer: Answer, status: integer, code: string, label: string)
   check.equal(answer.status, status, label)
   check.equal(client.text(answer, "error"), code, label .. " code")
end

local function pending_kept(answer: Answer, label: string)
   check.equal(#answer.set_cookies, 0, label .. ": no cookie changed")
   check.equal(#redis_admin.keys("edge:pending:*"), 1, label .. ": pending kept")
end

local function pending_ended(answer: Answer, label: string)
   check.equal(client.set_cookie(answer, "__Host-kx_pending"), EXPIRED_PENDING, label .. ": pending cookie expired")
   check.equal(#redis_admin.keys("edge:pending:*"), 0, label .. ": pending gone")
end

describe("passkey sign-in", function()
   before_each(function()
      fake.reset()
      redis_admin.flush()
   end)

   it("passes identity's passkeys flag on to the backoffice's challenge answer", function()
      local holder = flows.login("backoffice", "admin-passkey@example.test", nil)
      check.equal(holder.status, 200, "status")
      check.equal(names(holder.json), "mfaRequired,passkeys", "two keys")
      check.equal(client.flag(holder, "mfaRequired"), true, "mfa required")
      check.equal(client.flag(holder, "passkeys"), true, "a passkey is enrolled")

      local without = flows.login("backoffice", "admin-2fa@example.test", nil)
      check.equal(names(without.json), "mfaRequired,passkeys", "two keys")
      check.equal(client.flag(without, "passkeys"), false, "no passkey enrolled")
   end)

   it("answers passkeys false on the backoffice when identity says nothing about them", function()
      fake.configure({ passkeys_flag = "off" })
      local answer = flows.login("backoffice", "admin-passkey@example.test", nil)
      check.equal(answer.status, 200, "status")
      check.equal(names(answer.json), "mfaRequired,passkeys", "the key is always there on the backoffice")
      check.equal(client.flag(answer, "passkeys"), false, "false")
   end)

   it("keeps the seller web's challenge answer exactly as it was, whatever identity says", function()
      local answer = flows.login("seller-web", "seller-passkey@example.test", nil)
      check.equal(answer.status, 200, "status")
      check.equal(answer.body, "{\"mfaRequired\":true}", "no passkeys key")
      check.present(client.cookie_value(answer, "__Host-kx_pending"), "pending cookie")

      local plain = flows.login("seller-web", "seller-2fa@example.test", nil)
      check.equal(plain.body, "{\"mfaRequired\":true}", "no passkeys key without a passkey either")
   end)

   it("hands the browser identity's request options unchanged and keeps the pending sign-in", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      local request_id = client.request_id()
      local answer = client.edge(
         "POST",
         "/bff/2fa/passkey/options",
         { app = "backoffice", cookie = flows.pending(pending), request_id = request_id }
      )
      check.equal(answer.status, 200, "status")
      check.equal(names(answer.json), "options", "options only")

      local expected = json_relay.object(
         json_relay.document(passkey_fixture.options(fake.issued("passkey_challenge"))),
         "options"
      )
      local relayed = json_relay.object(json_relay.document(answer.body), "options")
      check.truthy(same(relayed, expected), "identity's options, unchanged")
      check.contains(answer.body, "\"transports\":[]", "an empty array stays an array")
      check.excludes(answer.body, fake.issued("challenge"), "no challenge token")
      pending_kept(answer, "options")

      local sent = json_relay.document(fake.body("passkey_options"))
      check.equal(names(sent), "challengeToken", "identity is sent the challenge only")
      check.equal(sent["challengeToken"], fake.issued("challenge"), "the pending challenge")
      local headers = fake.headers("passkey_options")
      check.equal(headers["x-kinetix-client"], "backoffice", "client name")
      check.equal(headers["x-forwarded-for"], scenario.browser_address, "the browser's address alone")
      check.equal(headers["x-request-id"], request_id, "request id")
   end)

   it("starts the session from a passkey exactly as from a code", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      check.equal(options("backoffice", pending).status, 200, "options")

      local body = credential_body(passkey_fixture.credential_id)
      local answer = verify("backoffice", pending, body)
      check.equal(answer.status, 200, "status")
      check.equal(names(answer.json), "authenticated,expiresAt,principalId,role", "the session view")
      check.equal(client.flag(answer, "authenticated"), true, "authenticated")
      check.equal(client.text(answer, "role"), "admin", "role")
      check.equal(client.text(answer, "principalId"), "prn_fake_107", "principal")
      check.excludes(answer.body, fake.issued("access"), "no access token")

      local session = client.cookie_value(answer, "__Host-kx_session")
      check.equal(#session, 43, "session value")
      check.equal(
         client.set_cookie(answer, "__Host-kx_session"),
         "__Host-kx_session=" .. session .. ATTRIBUTES,
         "the backoffice's browser-session cookie"
      )
      pending_ended(answer, "verified")
      check.equal(
         redis_admin.hash("edge:session:" .. digest.sha256_hex(session))["access_token"],
         fake.issued("access"),
         "identity's tokens kept in Redis"
      )

      local sent = json_relay.document(fake.body("passkey_verify"))
      check.equal(names(sent), "challengeToken,credential", "identity is sent the challenge and the credential")
      check.equal(sent["challengeToken"], fake.issued("challenge"), "the pending challenge")
      check.truthy(
         same(json_relay.object(sent, "credential"), json_relay.object(json_relay.document(body), "credential")),
         "the browser's credential, unchanged"
      )
      check.contains(fake.body("passkey_verify"), "\"clientExtensionResults\":{}", "an empty object stays an object")
      check.equal(fake.headers("passkey_verify")["x-kinetix-client"], "backoffice", "client name")

      local current = client.edge("GET", "/bff/session", { app = "backoffice", cookie = flows.session(session) })
      check.equal(client.flag(current, "authenticated"), true, "the session is usable")

      refused(verify("backoffice", pending, body), 401, "SIGN_IN_REQUIRED", "a spent pending sign-in")
   end)

   it("keeps the pending sign-in through a refused passkey, for another passkey or the code", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      options("backoffice", pending)

      local wrong = verify("backoffice", pending, credential_body(passkey_fixture.unknown_credential_id))
      refused(wrong, 401, "PASSKEY_REFUSED", "an unknown passkey")
      pending_kept(wrong, "refused passkey")

      local right = verify("backoffice", pending, credential_body(passkey_fixture.credential_id))
      check.equal(right.status, 200, "the right passkey, on the same pending sign-in")

      local again = pending_of("backoffice", "admin-passkey@example.test")
      options("backoffice", again)
      refused(
         verify("backoffice", again, credential_body(passkey_fixture.unknown_credential_id)),
         401,
         "PASSKEY_REFUSED",
         "refused again"
      )

      local code = client.edge(
         "POST",
         "/bff/2fa/verify",
         { app = "backoffice", cookie = flows.pending(again), body = client.json({ code = scenario.code }) }
      )
      check.equal(code.status, 200, "the code still answers the challenge")
      check.equal(client.text(code, "role"), "admin", "role")
   end)

   it("ends the pending sign-in when identity says the challenge is exhausted", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      options("backoffice", pending)
      for attempt = 1, 5 do
         refused(
            verify("backoffice", pending, credential_body(passkey_fixture.unknown_credential_id)),
            401,
            "PASSKEY_REFUSED",
            "refused " .. string.format("%d", attempt)
         )
      end

      local exhausted = verify("backoffice", pending, credential_body(passkey_fixture.credential_id))
      refused(exhausted, 401, "SIGN_IN_REQUIRED", "exhausted")
      pending_ended(exhausted, "exhausted")
   end)

   it("ends the pending sign-in when identity says the challenge was used or is unknown", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      local spent = client.call(
         scenario.identity_url,
         "POST",
         "/api/v1/auth/2fa/verify",
         { ["Content-Type"] = "application/json", ["X-Kinetix-Client"] = "backoffice" },
         client.json({ challengeToken = fake.issued("challenge"), code = scenario.code })
      )
      check.equal(spent.status, 200, "the challenge was answered elsewhere")

      local used = options("backoffice", pending)
      refused(used, 401, "SIGN_IN_REQUIRED", "options for a spent challenge")
      pending_ended(used, "spent")

      local other = pending_of("backoffice", "admin-passkey@example.test")
      redis_admin.set_field("edge:pending:" .. digest.sha256_hex(other), "token", "fake-challenge-unknown")
      local unknown = verify("backoffice", other, credential_body(passkey_fixture.credential_id))
      refused(unknown, 401, "SIGN_IN_REQUIRED", "verify for an unknown challenge")
      pending_ended(unknown, "unknown")
   end)

   it("refuses a credential that is not a JSON object before identity is asked", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      local bodies: {string} = {
         "{}",
         "{\"credential\":\"Y3JlZA\"}",
         "{\"credential\":[]}",
         "{\"credential\":[{\"id\":\"" .. passkey_fixture.credential_id .. "\"}]}",
         "{\"credential\":null}",
         "{\"credential\":true}",
         "[{\"credential\":{}}]",
         "{\"credential\":{\"id\":NaN}}",
         "{\"credential\":{\"id\":1e999}}",
         "{\"credential\":{\"id\":\"" .. string.rep("A", 16384) .. "\"}}",
         "not json",
      }
      for index, body in ipairs(bodies) do
         local answer = verify("backoffice", pending, body)
         refused(answer, 400, "INVALID_REQUEST", "body " .. string.format("%d", index))
      end

      refused(verify("backoffice", pending, nil), 400, "INVALID_REQUEST", "no body")
      check.equal(fake.count("passkey_verify"), 0, "identity was not asked")
      check.equal(#redis_admin.keys("edge:pending:*"), 1, "pending kept")
   end)

   it("asks for a sign-in when none is pending, and ends an enrolment brought to it", function()
      refused(options("backoffice", nil), 401, "SIGN_IN_REQUIRED", "options without a pending sign-in")
      refused(
         verify("backoffice", nil, credential_body(passkey_fixture.credential_id)),
         401,
         "SIGN_IN_REQUIRED",
         "verify without a pending sign-in"
      )

      local enrolment = pending_of("backoffice", "admin-new@example.test")
      local answer = options("backoffice", enrolment)
      refused(answer, 401, "SIGN_IN_REQUIRED", "an enrolment is not a challenge")
      pending_ended(answer, "enrolment")
      check.equal(fake.count("passkey_options"), 0, "identity was not asked")
      check.equal(fake.count("passkey_verify"), 0, "identity was not asked")
   end)

   it("answers 503 and keeps the pending sign-in when identity cannot be reached", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      fake.configure({ passkey_mode = "unavailable" })
      local answer = options("backoffice", pending)
      refused(answer, 503, "IDENTITY_UNAVAILABLE", "options")
      pending_kept(answer, "options")

      fake.configure({ passkey_mode = "close" })
      local closed = verify("backoffice", pending, credential_body(passkey_fixture.credential_id))
      refused(closed, 503, "IDENTITY_UNAVAILABLE", "verify")
      pending_kept(closed, "verify")
   end)

   it("refuses the passkey and keeps the code when the account's passkeys went after the password", function()
      local pending = pending_of("backoffice", "admin-2fa@example.test")
      local answer = options("backoffice", pending)
      refused(answer, 401, "PASSKEY_REFUSED", "no passkey left")
      pending_kept(answer, "no passkey left")

      local code = client.edge(
         "POST",
         "/bff/2fa/verify",
         { app = "backoffice", cookie = flows.pending(pending), body = client.json({ code = scenario.code }) }
      )
      check.equal(code.status, 200, "the code still answers the challenge")
   end)

   it("calls an answer without an options object not understood", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      fake.configure({ passkey_mode = "malformed" })
      local answer = options("backoffice", pending)
      refused(answer, 502, "IDENTITY_FAILED", "an array is not the options")
      pending_kept(answer, "malformed")
   end)

   it("refuses a role the backoffice does not admit and logs the tokens out at identity", function()
      fake.configure({ roles = { ["admin-passkey@example.test"] = "seller" } })
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      options("backoffice", pending)

      local answer = verify("backoffice", pending, credential_body(passkey_fixture.credential_id))
      refused(answer, 403, "ROLE_REFUSED", "a seller on the backoffice")
      check.absent(client.set_cookie(answer, "__Host-kx_session"), "no session cookie")
      pending_ended(answer, "role refused")
      check.equal(#redis_admin.keys("edge:session:*"), 0, "no session kept")
      check.equal(fake.count("logout"), 1, "logged out at identity")
      check.truthy(fake.revoked(fake.issued("refresh")), "the refresh family ended")
   end)

   it("serves neither route on the seller web", function()
      local pending = pending_of("seller-web", "seller-passkey@example.test")
      refused(options("seller-web", pending), 404, "NOT_FOUND", "options")
      refused(
         verify("seller-web", pending, credential_body(passkey_fixture.credential_id)),
         404,
         "NOT_FOUND",
         "verify"
      )
      check.equal(fake.count("passkey_options"), 0, "identity was not asked")
      check.equal(fake.count("passkey_verify"), 0, "identity was not asked")
      check.equal(#redis_admin.keys("edge:pending:*"), 1, "pending kept")
   end)

   it("refuses forged requests on both routes before anything is asked", function()
      local pending = pending_of("backoffice", "admin-passkey@example.test")
      local foreign = client.edge(
         "POST",
         "/bff/2fa/passkey/options",
         { app = "backoffice", cookie = flows.pending(pending), origin = "https://evil.example" }
      )
      refused(foreign, 403, "CSRF_REFUSED", "options from another origin")

      local cross = client.edge(
         "POST",
         "/bff/2fa/passkey/verify",
         {
            app = "backoffice",
            cookie = flows.pending(pending),
            omit_origin = true,
            fetch_site = "cross-site",
            body = credential_body(passkey_fixture.credential_id),
         }
      )
      refused(cross, 403, "CSRF_REFUSED", "verify from another site")

      local form = client.edge(
         "POST",
         "/bff/2fa/passkey/verify",
         {
            app = "backoffice",
            cookie = flows.pending(pending),
            content_type = "text/plain",
            body = credential_body(passkey_fixture.credential_id),
         }
      )
      refused(form, 415, "JSON_REQUIRED", "verify without JSON")
      check.equal(fake.count("passkey_options"), 0, "identity was not asked")
      check.equal(fake.count("passkey_verify"), 0, "identity was not asked")
      check.equal(#redis_admin.keys("edge:pending:*"), 1, "pending kept")
   end)

   it("takes POST only", function()
      local answer = client.edge("GET", "/bff/2fa/passkey/options", { app = "backoffice" })
      refused(answer, 405, "METHOD_NOT_ALLOWED", "GET")
      check.equal(client.header(answer, "Allow"), "POST", "Allow")
   end)
end)

describe("passkey management through the API forwarder", function()
   local cookie: string = nil

   before_each(function()
      fake.reset()
      redis_admin.flush()
      cookie = flows.session(flows.admin_session_cookie())
   end)

   local function reached_identity(path: string, method: string, body: string, label: string)
      check.equal(fake.count("passkeys"), 1, label .. ": identity answered")
      check.equal(fake.path("passkeys"), path, label .. ": path")
      check.equal(fake.method("passkeys"), method, label .. ": method")
      check.equal(fake.body("passkeys"), body, label .. ": body unchanged")

      local headers = fake.headers("passkeys")
      check.equal(headers["authorization"], "Bearer " .. fake.issued("access"), label .. ": the session's bearer")
      check.equal(headers["x-kinetix-client"], "backoffice", label .. ": client name")
      check.equal(headers["x-forwarded-for"], scenario.browser_address, label .. ": the browser's address alone")
      check.absent(headers["cookie"], label .. ": no cookie")
   end

   local function call(method: string, path: string, body: string): Answer
      return client.edge(method, "/bff" .. path, { app = "backoffice", cookie = cookie, body = body })
   end

   it("lists the account's passkeys", function()
      local answer = call("GET", "/api/v1/auth/passkeys/105", nil)
      check.equal(answer.status, 200, "status")
      check.equal(answer.body, "{\"passkeys\":[" .. passkey_fixture.created .. "]}", "identity's answer")
      reached_identity("/api/v1/auth/passkeys/105", "GET", "", "list")
   end)

   it("asks for creation options with a state change that carries no body", function()
      local answer = call("POST", "/api/v1/auth/passkeys/105/options", nil)
      check.equal(answer.status, 200, "status")
      check.equal(answer.body, passkey_fixture.creation_options, "identity's answer")
      reached_identity("/api/v1/auth/passkeys/105/options", "POST", "", "options")
      check.equal(fake.headers("passkeys")["content-length"], "0", "an empty body")
   end)

   it("enrols a passkey with its body unchanged", function()
      local body = "{\"challengeId\":\"7d8e3c1a-5b2f-4a61-9c3e-2f1b0a9d8c7e\",\"name\":\"Laptop\","
         .. "\"password\":\"" .. scenario.password .. "\",\"credential\":{\"id\":\"" .. passkey_fixture.credential_id
         .. "\",\"response\":{\"transports\":[]},\"clientExtensionResults\":{}}}"
      local answer = call("POST", "/api/v1/auth/passkeys/105", body)
      check.equal(answer.status, 201, "status")
      check.equal(answer.body, passkey_fixture.created, "identity's answer")
      reached_identity("/api/v1/auth/passkeys/105", "POST", body, "enrol")
      check.equal(fake.headers("passkeys")["content-type"], "application/json", "content type")
   end)

   it("removes a passkey with a DELETE that carries a body", function()
      local body = client.json({ password = scenario.password })
      local path = "/api/v1/auth/passkeys/105/0f6c2d4e-8a1b-4c3d-9e5f-6a7b8c9d0e1f"
      local answer = call("DELETE", path, body)
      check.equal(answer.status, 204, "status")
      check.equal(answer.body, "", "no body")
      reached_identity(path, "DELETE", body, "remove")
      check.equal(fake.headers("passkeys")["content-type"], "application/json", "content type")
      check.equal(fake.headers("passkeys")["content-length"], string.format("%d", #body), "length")
   end)

   it("never forwards identity's passkey sign-in, which issues tokens", function()
      local answer = call("POST", "/api/v1/auth/2fa/passkey/verify", credential_body(passkey_fixture.credential_id))
      refused(answer, 404, "NOT_FOUND", "passkey verify")
      check.equal(fake.count("passkey_verify"), 0, "identity was not asked")
   end)
end)
