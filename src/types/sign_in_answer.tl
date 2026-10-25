local type SignInKind = require("types.sign_in_kind")
local type TokenGrant = require("types.token_grant")

local record SignInAnswer
   kind: SignInKind
   grant: TokenGrant
   token: string
   user_id: integer
   expires_in: integer
end

return SignInAnswer
