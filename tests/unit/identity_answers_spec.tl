local check = require("tests.support.check")
local identity_answers = require("http.identity_answers")

local PAIR = [[{"accessToken":"a.b.c","refreshToken":"r.s.t","expiresIn":900,"tokenType":"Bearer",
"user":{"id":7,"email":"x@example.test","role":"seller","principalId":"prn_1"}}]]

describe("identity_answers", function()
   it("reads identity's token pair, with the role and principal from user", function()
      local answer = identity_answers.sign_in(identity_answers.document(PAIR))
      check.equal(answer.kind, "session", "kind")
      check.equal(answer.grant.access_token, "a.b.c", "access")
      check.equal(answer.grant.refresh_token, "r.s.t", "refresh")
      check.equal(answer.grant.expires_in, 900, "expires in")
      check.equal(answer.grant.role, "seller", "role")
      check.equal(answer.grant.principal_id, "prn_1", "principal")
   end)

   it("reads a two-factor challenge", function()
      local answer = identity_answers.sign_in(
         identity_answers.document([[{"mfaRequired":true,"challengeToken":"c.h.l","expiresIn":300}]])
      )
      check.equal(answer.kind, "challenge", "kind")
      check.equal(answer.token, "c.h.l", "token")
      check.equal(answer.expires_in, 300, "lifetime")
      check.equal(answer.passkeys, false, "no passkeys named")
   end)

   it("reads whether the challenge can be answered with a passkey", function()
      local with = identity_answers.sign_in(
         identity_answers.document([[{"mfaRequired":true,"challengeToken":"c","expiresIn":300,"passkeys":true}]])
      )
      check.equal(with.kind, "challenge", "kind")
      check.equal(with.passkeys, true, "passkeys")

      local without = identity_answers.sign_in(
         identity_answers.document([[{"mfaRequired":true,"challengeToken":"c","expiresIn":300,"passkeys":false}]])
      )
      check.equal(without.passkeys, false, "no passkeys")

      local loose = identity_answers.sign_in(
         identity_answers.document([[{"mfaRequired":true,"challengeToken":"c","expiresIn":300,"passkeys":"yes"}]])
      )
      check.equal(loose.passkeys, false, "only a boolean true counts")
   end)

   it("reads an admin's restricted enrolment session", function()
      local answer = identity_answers.sign_in(identity_answers.document(
         [[{"mfaEnrolmentRequired":true,"enrolmentToken":"e.n.r","tokenType":"Bearer","expiresIn":600,"userId":42}]]
      ))
      check.equal(answer.kind, "enrolment", "kind")
      check.equal(answer.token, "e.n.r", "token")
      check.equal(answer.user_id, 42, "user id")
      check.equal(answer.expires_in, 600, "lifetime")
   end)

   it("calls anything else malformed rather than guessing", function()
      check.equal(identity_answers.sign_in(identity_answers.document("{}")).kind, "malformed", "empty object")
      check.equal(identity_answers.sign_in(identity_answers.document("[]")).kind, "malformed", "array")
      check.equal(identity_answers.sign_in(identity_answers.document("not json")).kind, "malformed", "not json")
      local no_user = identity_answers.document([[{"accessToken":"a","refreshToken":"r","expiresIn":9}]])
      check.equal(identity_answers.sign_in(no_user).kind, "malformed", "no user")
      check.equal(
         identity_answers.sign_in(identity_answers.document([[{"mfaRequired":true,"expiresIn":300}]])).kind,
         "malformed",
         "challenge without token"
      )
   end)

   it("reads identity's error code and a numeric Retry-After", function()
      check.equal(
         identity_answers.error_code(identity_answers.document([[{"error":"SIGN_IN_DELAYED","message":"m"}]])),
         "SIGN_IN_DELAYED",
         "code"
      )
      check.equal(identity_answers.retry_after({ ["Retry-After"] = "17" }), "17", "retry after")
      check.absent(identity_answers.retry_after({ ["Retry-After"] = "soon" }), "not a number")
   end)

   it("tells a challenge that ended from a wrong code, and an identity without codes from both", function()
      check.truthy(identity_answers.ends_challenge("CHALLENGE_EXHAUSTED"), "exhausted")
      check.truthy(identity_answers.ends_challenge("CHALLENGE_SPENT"), "spent")
      check.truthy(identity_answers.ends_challenge("CHALLENGE_INVALID"), "invalid")
      check.falsy(identity_answers.ends_challenge("WRONG_CODE"), "a wrong code keeps the challenge")
      check.falsy(identity_answers.ends_challenge("Unauthorized"), "Nest's default")
      check.falsy(identity_answers.ends_challenge(nil), "no code")
   end)

   it("reads identity's validation messages, one or many", function()
      check.equal(
         identity_answers.validation_message(identity_answers.document([[{"message":["a must be b","c must be d"]}]])),
         "a must be b; c must be d",
         "Nest's list"
      )
      check.equal(
         identity_answers.validation_message(identity_answers.document([[{"message":"a must be b"}]])),
         "a must be b",
         "one"
      )
      check.absent(identity_answers.validation_message(identity_answers.document([[{"message":[]}]])), "none")
      local long = "{\"message\":\"" .. string.rep("x", 501) .. "\"}"
      check.absent(identity_answers.validation_message(identity_answers.document(long)), "too long to relay")
   end)
end)
