local check = require("tests.support.check")
local csrf = require("http.csrf")

local ORIGIN = "https://seller.localhost:8443"

describe("csrf", function()
   it("lets safe methods through without asking anything", function()
      check.absent(csrf.refusal("GET", nil, "cross-site", ORIGIN), "GET")
      check.absent(csrf.refusal("HEAD", "https://evil.example", nil, ORIGIN), "HEAD")
   end)

   it("accepts a state-changing request from the application's own origin", function()
      check.absent(csrf.refusal("POST", ORIGIN, nil, ORIGIN), "own origin")
   end)

   it("refuses another origin, even with a same-origin fetch site", function()
      check.equal(csrf.refusal("POST", "https://evil.example", "same-origin", ORIGIN), "origin", "foreign origin")
      check.equal(csrf.refusal("DELETE", "https://backoffice.localhost:8443", nil, ORIGIN), "origin", "sibling app")
      check.equal(csrf.refusal("PUT", "null", nil, ORIGIN), "origin", "opaque origin")
      check.equal(csrf.refusal("PATCH", "http://seller.localhost:8443", nil, ORIGIN), "origin", "plain http")
   end)

   it("falls back to Sec-Fetch-Site only when there is no Origin", function()
      check.absent(csrf.refusal("POST", nil, "same-origin", ORIGIN), "same-origin")
      check.equal(csrf.refusal("POST", nil, "same-site", ORIGIN), "fetch_site", "same-site")
      check.equal(csrf.refusal("POST", nil, "cross-site", ORIGIN), "fetch_site", "cross-site")
      check.equal(csrf.refusal("POST", nil, "none", ORIGIN), "fetch_site", "none")
      check.equal(csrf.refusal("POST", nil, nil, ORIGIN), "fetch_site", "neither header")
   end)

   it("treats OPTIONS as state-changing, since nothing answers CORS", function()
      check.equal(csrf.refusal("OPTIONS", nil, nil, ORIGIN), "fetch_site", "OPTIONS")
   end)

   it("accepts JSON bodies only", function()
      check.truthy(csrf.is_json("application/json"), "plain")
      check.truthy(csrf.is_json("Application/JSON; charset=utf-8"), "with charset")
      check.falsy(csrf.is_json("text/plain"), "text/plain")
      check.falsy(csrf.is_json("application/x-www-form-urlencoded"), "form")
      check.falsy(csrf.is_json("multipart/form-data; boundary=x"), "multipart")
      check.falsy(csrf.is_json("application/json-patch+json"), "json-patch")
      check.falsy(csrf.is_json(nil), "missing")
   end)
end)
