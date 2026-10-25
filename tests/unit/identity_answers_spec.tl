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
end)
