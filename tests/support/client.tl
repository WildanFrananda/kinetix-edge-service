local cjson = require("cjson.safe")
local http = require("resty.http")
local scenario = require("tests.support.scenario")
local type Answer = require("tests.support.types.answer")
local type EdgeRequest = require("tests.support.types.edge_request")

local record client
end

local sequence = 0

local STATE_CHANGING: {string: boolean} = { ["POST"] = true, ["PUT"] = true, ["PATCH"] = true, ["DELETE"] = true }

local function set_cookies_of(headers: {string: http.HeaderValue}): {string}
   local value = headers["Set-Cookie"]
   if value == nil then
      return {}
   end

   if value is string then
      return { value }
   end

   return value
end

function client.call(base: string, method: string, path: string, headers: {string: string}, body: string): Answer
   local connection = http.new()
   connection:set_timeouts(2000, 5000, 20000)

   local sent = body
   if sent == nil and STATE_CHANGING[method] then
      sent = ""
   end

   local response, failure = connection:request_uri(base .. path, { method = method, headers = headers, body = sent })
   if response == nil then
      error("no answer from " .. base .. path .. ": " .. tostring(failure))
   end

   local decoded = cjson.decode(response.body or "")
   local document: cjson.Document = nil
   if decoded is cjson.Document then
      document = decoded
   end

   return {
      status = response.status,
      headers = response.headers,
      body = response.body or "",
      json = document,
      set_cookies = set_cookies_of(response.headers),
   }
end

local function remember_secrets(values: {string})
   local path = os.getenv("EDGE_TEST_OBSERVED")
   if path == nil or #values == 0 then
      return
   end

   local file = io.open(path, "a")
   if file == nil then
      return
   end

   for _, value in ipairs(values) do
      file:write(value, "\n")
   end

   file:close()
end

function client.observe(answer: Answer)
   local values: {string} = {}
   for _, cookie in ipairs(answer.set_cookies) do
      local value = string.match(cookie, "^__Host%-kx_%a+=([^;]+)")
      if value ~= nil then
         table.insert(values, value)
      end
   end

   remember_secrets(values)
end

function client.observe_secret(value: string)
   remember_secrets({ value })
end

function client.request_id(): string
   sequence = sequence + 1

   return "itest-" .. string.format("%d", ngx.worker.pid()) .. "-" .. string.format("%d", sequence)
end

function client.edge(method: string, path: string, request: EdgeRequest): Answer
   local options: EdgeRequest = request or {}
   local app = options.app or "seller-web"
   local headers: {string: string} = {
      ["Host"] = options.host or scenario.hosts[app],
      ["X-Request-Id"] = options.request_id or client.request_id(),
   }
   if not options.omit_forwarded_for then
      headers["X-Forwarded-For"] = options.forwarded_for or scenario.forwarded_for
   end

   if STATE_CHANGING[method] and not options.omit_origin then
      headers["Origin"] = options.origin or scenario.origin(app)
   end

   if options.fetch_site ~= nil then
      headers["Sec-Fetch-Site"] = options.fetch_site
   end

   if options.cookie ~= nil then
      headers["Cookie"] = options.cookie
   end

   if options.body ~= nil then
      headers["Content-Type"] = options.content_type or "application/json"
   end

   for name, value in pairs(options.headers or {}) do
      headers[name] = value
   end

   local answer = client.call(scenario.edge_url, method, path, headers, options.body)
   client.observe(answer)

   return answer
end

function client.json<T>(value: T): string
   local text = cjson.encode(value)

   return text
end

function client.set_cookie(answer: Answer, name: string): string
   for _, cookie in ipairs(answer.set_cookies) do
      if string.sub(cookie, 1, #name + 1) == name .. "=" then
         return cookie
      end
   end

   return nil
end

function client.cookie_value(answer: Answer, name: string): string
   local cookie = client.set_cookie(answer, name)
   if cookie == nil then
      return nil
   end

   return string.match(cookie, "^[^=]+=([^;]*)")
end

function client.text(answer: Answer, name: string): string
   if answer.json == nil then
      return nil
   end

   local value = answer.json[name]
   if value is string then
      return value
   end

   return nil
end

function client.flag(answer: Answer, name: string): boolean
   if answer.json == nil then
      return nil
   end

   local value = answer.json[name]
   if value is boolean then
      return value
   end

   return nil
end

function client.header(answer: Answer, name: string): string
   local value = answer.headers[name]
   if value is string then
      return value
   end

   if value == nil then
      return nil
   end

   return table.concat(value, ", ")
end

return client
