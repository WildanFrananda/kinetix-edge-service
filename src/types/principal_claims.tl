local type PrincipalClass = require("types.principal_class")

local record PrincipalClaims
   has_bearer: boolean
   valid_shape: boolean
   sub: string
   role: string
   token_use: string
   audience_ok: boolean
   principal_class: PrincipalClass
end

return PrincipalClaims
