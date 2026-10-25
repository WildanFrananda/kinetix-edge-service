local cjson = require("cjson.safe")
local client = require("tests.support.client")
local scenario = require("tests.support.scenario")

local record fake
   type Settings = {string: string | number | {string: string}}
end

local JSON: {string: string} = { ["Content-Type"] = "application/json" }

function fake.reset()
   client.call(scenario.identity_url, "POST", "/__fake/reset", JSON, "{}")
end

function fake.configure(settings: fake.Settings)
   local body = cjson.encode(settings)
   client.call(scenario.identity_url, "POST", "/__fake/settings", JSON, body)
end

function fake.state(): cjson.Document
   return client.call(scenario.identity_url, "GET", "/__fake/state", {}, nil).json
end

local function section(name: string): cjson.Object
   local value = fake.state()[name]
   if value is cjson.Object then
      return value
   end

   return {}
end

function fake.count(endpoint: string): integer
   local value = section("counters")[endpoint]
   if value is number then
      return math.floor(value)
   end

   return 0
end

function fake.issued(kind: string): string
   local value = section("issued")[kind]
   if value is string then
      return value
   end

   return nil
end

function fake.path(endpoint: string): string
   local value = section("paths")[endpoint]
   if value is string then
      return value
   end

   return nil
end

function fake.headers(endpoint: string): {string: string}
   local raw = client.call(scenario.identity_url, "GET", "/__fake/state", {}, nil).body
   local decoded = cjson.decode(raw)
   if not decoded is cjson.Document then
      return {}
   end

   local everything = decoded["headers"] as {string: {string: string}}
   if everything == nil or everything[endpoint] == nil then
      return {}
   end

   return everything[endpoint]
end

function fake.revoked(refresh_token: string): boolean
   local value = section("revoked")[refresh_token]

   return value is boolean and value
end

return fake
