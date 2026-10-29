local record FakeUser
   id: integer
   email: string
   password: string
   role: string
   principal_id: string
   two_factor: boolean
   passkeys: boolean
   secret_issued: boolean
end

return FakeUser
