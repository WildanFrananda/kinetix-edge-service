local cjson = require("cjson.safe")
local http = require("resty.http")
local type SignInAnswer = require("types.sign_in_answer")
local type TokenGrant = require("types.token_grant")

local record identity_answers
end

local function text(document: cjson.Document, name: string): string
   local value = document[name]
   if value is string and #value > 0 then
      return value
   end

   return nil
end

local function positive_integer(document: cjson.Document, name: string): integer
   local value = document[name]
   if value is number and value > 0 and value == math.floor(value) then
      return math.floor(value)
   end

   return nil
end

local function flag(document: cjson.Document, name: string): boolean
   local value = document[name]

   return value is boolean and value
end

function identity_answers.document(body: string): cjson.Document
   if body == nil or body == "" then
      return nil
   end

   local decoded = cjson.decode(body)
   if decoded is cjson.Document then
      return decoded
   end

   return nil
end

function identity_answers.grant(document: cjson.Document): TokenGrant
   if document == nil then
      return nil
   end

   local access_token = text(document, "accessToken")
   local refresh_token = text(document, "refreshToken")
   local expires_in = positive_integer(document, "expiresIn")
   local user = document["user"]
   if access_token == nil or refresh_token == nil or expires_in == nil or not user is cjson.Object then
      return nil
   end

   local role = user["role"]
   local principal_id = user["principalId"]
   if not role is string or not principal_id is string or #role == 0 or #principal_id == 0 then
      return nil
   end

   return {
      access_token = access_token,
      refresh_token = refresh_token,
      expires_in = expires_in,
      role = role,
      principal_id = principal_id,
   }
end

function identity_answers.sign_in(document: cjson.Document): SignInAnswer
   if document == nil then
      return { kind = "malformed" }
   end

   if flag(document, "mfaRequired") then
      local challenge = text(document, "challengeToken")
      local expires_in = positive_integer(document, "expiresIn")
      if challenge == nil or expires_in == nil then
         return { kind = "malformed" }
      end

      return { kind = "challenge", token = challenge, expires_in = expires_in }
   end

   if flag(document, "mfaEnrolmentRequired") then
      local enrolment = text(document, "enrolmentToken")
      local user_id = positive_integer(document, "userId")
      local expires_in = positive_integer(document, "expiresIn")
      if enrolment == nil or user_id == nil or expires_in == nil then
         return { kind = "malformed" }
      end

      return { kind = "enrolment", token = enrolment, user_id = user_id, expires_in = expires_in }
   end

   local grant = identity_answers.grant(document)
   if grant == nil then
      return { kind = "malformed" }
   end

   return { kind = "session", grant = grant }
end

function identity_answers.error_code(document: cjson.Document): string
   if document == nil then
      return nil
   end

   return text(document, "error")
end

function identity_answers.retry_after(headers: {string: http.HeaderValue}): string
   if headers == nil then
      return nil
   end

   local value = headers["Retry-After"] or headers["retry-after"]
   if value is string and string.match(value, "^%d+$") ~= nil and #value <= 6 then
      return value
   end

   return nil
end

return identity_answers
