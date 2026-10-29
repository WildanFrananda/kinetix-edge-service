local record FakeSettings
   refresh_mode: string
   refresh_delay_ms: integer
   login_mode: string
   logout_mode: string
   register_mode: string
   verify_codes: string
   passkeys_flag: string
   passkey_mode: string
   access_expires_in: integer
   roles: {string: string}
end

return FakeSettings
