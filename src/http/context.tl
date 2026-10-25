local client_address = require("http.client_address")
local http = require("resty.http")
local request_id = require("http.request_id")
local settings = require("http.settings")
local type AppPolicy = require("types.app_policy")
local type RequestContext = require("types.request_context")

local record context
end

function context.single(headers: {string: http.HeaderValue}, name: string): string
   local value = headers[name]
   if value is string then
      return value
   end

   return nil
end

function context.joined(headers: {string: http.HeaderValue}, name: string, separator: string): string
   local value = headers[name]
   if value == nil or value is string then
      return value as string
   end

   return table.concat(value, separator)
end

function context.app_for(host: string): AppPolicy
   if host == nil then
      return nil
   end

   local hostname = string.gsub(string.lower(host), ":%d+$", "")
   for _, app in ipairs(settings.current.apps) do
      if app.hostname == hostname then
         return app
      end
   end

   return nil
end

function context.request_id(headers: {string: http.HeaderValue}): string
   local incoming = request_id.accepted(context.single(headers, "x-request-id"))
   if incoming ~= nil then
      return incoming
   end

   return ngx.var.request_id
end

function context.build(headers: {string: http.HeaderValue}, id: string, for_app: boolean): RequestContext, string
   local built: RequestContext = { request_id = id, method = ngx.req.get_method(), headers = headers }
   if not for_app then
      return built, nil
   end

   built.app = context.app_for(context.single(headers, "host"))
   if built.app == nil then
      return nil, "NOT_FOUND"
   end

   built.client_address = client_address.from_forwarded_for(context.joined(headers, "x-forwarded-for", ","))
   if built.client_address == nil then
      return nil, "CLIENT_ADDRESS_REQUIRED"
   end

   return built, nil
end

return context
