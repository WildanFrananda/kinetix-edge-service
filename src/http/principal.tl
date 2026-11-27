local cjson = require("cjson.safe")
local event_protocol = require("http.event_protocol")
local type ApiRouteRule = require("types.api_route_rule")
local type AuthCheckResult = require("types.auth_check_result")
local type PrincipalClaims = require("types.principal_claims")
local type PrincipalClass = require("types.principal_class")

local record principal
end

local ROLE_MAP: {string: PrincipalClass} = {
   ["customer"] = "buyer",
   ["buyer"] = "buyer",
   ["seller"] = "seller",
   ["courier"] = "courier",
   ["admin"] = "admin",
}

local function decode_base64url(segment: string): string
   if segment == nil or segment == "" then
      return nil
   end

   local padded = string.gsub(string.gsub(segment, "-", "+"), "_", "/")
   local rem = #padded % 4
   if rem == 2 then
      padded = padded .. "=="
   elseif rem == 3 then
      padded = padded .. "="
   elseif rem == 1 then
      return nil
   end

   return ngx.decode_base64(padded)
end

function principal.class_of_role(role: string): PrincipalClass
   if role == nil or role == "" then
      return "anonymous"
   end

   return ROLE_MAP[string.lower(role)] or "anonymous"
end

local function matches_audience(decoded: cjson.Document, expected: string): boolean
   if expected == nil or expected == "" then
      return true
   end

   local raw_aud = decoded["aud"]
   if raw_aud is string then
      return raw_aud == expected
   end

   return false
end

local function empty_claims(has_bearer: boolean): PrincipalClaims
   return {
      has_bearer = has_bearer,
      valid_shape = false,
      audience_ok = false,
      principal_class = "anonymous",
   }
end

function principal.inspect(authorization: string, expected_audience: string): PrincipalClaims
   local token = event_protocol.bearer_token(authorization)
   if token == nil then
      return empty_claims(false)
   end

   local _, payload = string.match(token, "^([^%.]+)%.([^%.]+)%.[^%.]+$")
   if payload == nil then
      return empty_claims(true)
   end

   local raw_json = decode_base64url(payload)
   if raw_json == nil then
      return empty_claims(true)
   end

   local decoded = cjson.decode(raw_json)
   if not (decoded is cjson.Document) then
      return empty_claims(true)
   end

   local raw_sub = decoded["sub"]
   local raw_role = decoded["role"]
   local raw_use = decoded["token_use"]
   local role = raw_role is string and string.lower(raw_role) or nil
   local sub = raw_sub is string and raw_sub or nil
   local token_use = raw_use is string and raw_use or nil

   return {
      has_bearer = true,
      valid_shape = true,
      sub = sub,
      role = role,
      token_use = token_use,
      audience_ok = matches_audience(decoded, expected_audience),
      principal_class = principal.class_of_role(role),
   }
end

function principal.authorize(claims: PrincipalClaims, rule: ApiRouteRule): AuthCheckResult
   if not rule.require_auth then
      return { ok = true, reason = "public" }
   end

   if not claims.has_bearer or not claims.valid_shape then
      return { ok = false, reason = "token_required", error_code = "TOKEN_REQUIRED" }
   end

   if claims.sub == nil or claims.sub == "" then
      return { ok = false, reason = "token_required", error_code = "TOKEN_REQUIRED" }
   end

   if claims.token_use ~= "access" then
      return { ok = false, reason = "wrong_token_use", error_code = "TOKEN_REQUIRED" }
   end

   if not claims.audience_ok then
      return { ok = false, reason = "wrong_audience", error_code = "TOKEN_REQUIRED" }
   end

   if rule.allowed_roles ~= nil and #rule.allowed_roles > 0 then
      if claims.role == nil then
         return { ok = false, reason = "role_refused", error_code = "FORBIDDEN" }
      end

      local matched = false
      for _, allowed in ipairs(rule.allowed_roles) do
         if claims.role == allowed then
            matched = true
            break
         end
      end

      if not matched then
         return { ok = false, reason = "role_refused", error_code = "FORBIDDEN" }
      end
   end

   return { ok = true, reason = "allowed" }
end

function principal.class_from_bearer(authorization: string): PrincipalClass
   return principal.inspect(authorization, nil).principal_class
end

return principal
