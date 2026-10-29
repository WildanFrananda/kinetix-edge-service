local type EdgeError = require("types.edge_error")

local record errors
   catalogue: {string: EdgeError}
end

local function entry(status: integer, code: string, message: string): EdgeError
   return { status = status, code = code, message = message }
end

errors.catalogue = {
   INVALID_REQUEST = entry(400, "INVALID_REQUEST", "The request body is not what this endpoint takes."),
   CLIENT_ADDRESS_REQUIRED = entry(
      400,
      "CLIENT_ADDRESS_REQUIRED",
      "This request did not arrive through the gateway, so the edge cannot tell who sent it."
   ),
   SIGN_IN_REFUSED = entry(401, "SIGN_IN_REFUSED", "The email or the password is not correct."),
   CODE_REFUSED = entry(
      401,
      "CODE_REFUSED",
      "The code was not accepted. Try the next one, or sign in again if this keeps happening."
   ),
   PASSKEY_REFUSED = entry(
      401,
      "PASSKEY_REFUSED",
      "The passkey was not accepted. Try again, or use the code from the authenticator app."
   ),
   SIGN_IN_REQUIRED = entry(401, "SIGN_IN_REQUIRED", "No sign-in is in progress, or it has expired. Sign in again."),
   SESSION_REQUIRED = entry(401, "SESSION_REQUIRED", "Sign in first."),
   SESSION_ENDED = entry(401, "SESSION_ENDED", "The session has ended. Sign in again."),
   CSRF_REFUSED = entry(
      403,
      "CSRF_REFUSED",
      "This request did not come from the application's own page, so nothing was done."
   ),
   ROLE_REFUSED = entry(403, "ROLE_REFUSED", "This account cannot use this application."),
   SELLER_REQUIRED = entry(
      403,
      "SELLER_REQUIRED",
      "Only a seller account can open the merchant socket. The session is unchanged."
   ),
   NOT_FOUND = entry(404, "NOT_FOUND", "Nothing is served at this path."),
   METHOD_NOT_ALLOWED = entry(405, "METHOD_NOT_ALLOWED", "This path does not take that method."),
   EMAIL_TAKEN = entry(409, "EMAIL_TAKEN", "An account with this email address already exists. Sign in instead."),
   TWO_FACTOR_ALREADY_ENABLED = entry(
      409,
      "TWO_FACTOR_ALREADY_ENABLED",
      "Two-factor authentication is already enabled for this account. Sign in again."
   ),
   PAYLOAD_TOO_LARGE = entry(413, "PAYLOAD_TOO_LARGE", "The request body is larger than the edge accepts."),
   URI_TOO_LONG = entry(414, "URI_TOO_LONG", "The request path is longer than the edge accepts."),
   HEADERS_TOO_LARGE = entry(431, "HEADERS_TOO_LARGE", "The request headers are larger than the edge accepts."),
   JSON_REQUIRED = entry(415, "JSON_REQUIRED", "Request bodies must be application/json."),
   WEBSOCKET_REQUIRED = entry(426, "WEBSOCKET_REQUIRED", "This path takes a WebSocket upgrade only."),
   SIGN_IN_DELAYED = entry(
      429,
      "SIGN_IN_DELAYED",
      "Too many unsuccessful sign-in attempts for this account. Nothing was checked; try again after Retry-After."
   ),
   TOO_MANY_REQUESTS = entry(429, "TOO_MANY_REQUESTS", "Too many requests. Try again after Retry-After."),
   INTERNAL_ERROR = entry(
      500,
      "INTERNAL_ERROR",
      "Something went wrong in the edge, and it is not known how much of this request took effect."
   ),
   IDENTITY_FAILED = entry(
      502,
      "IDENTITY_FAILED",
      "identity answered in a way the edge does not understand, so nothing was decided."
   ),
   SESSION_STORE_UNAVAILABLE = entry(
      503,
      "SESSION_STORE_UNAVAILABLE",
      "The session store could not be reached, so nothing was checked. Try again later."
   ),
   IDENTITY_UNAVAILABLE = entry(
      503,
      "IDENTITY_UNAVAILABLE",
      "identity could not be reached, so nothing was decided. Try again later."
   ),
   API_UNAVAILABLE = entry(
      503,
      "API_UNAVAILABLE",
      "The API could not be reached, and it is not known whether the request took effect. Read the current state first."
   ),
}

local NGINX_REFUSALS: {integer: string} = {
   [400] = "INVALID_REQUEST",
   [413] = "PAYLOAD_TOO_LARGE",
   [414] = "URI_TOO_LONG",
   [494] = "HEADERS_TOO_LARGE",
}

function errors.for_status(status: integer): EdgeError
   local code = NGINX_REFUSALS[status]
   if code == nil then
      return errors.catalogue["INTERNAL_ERROR"]
   end

   return errors.catalogue[code]
end

return errors
