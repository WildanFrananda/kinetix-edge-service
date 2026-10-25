local record FakeSettings
   refresh_mode: string
   refresh_delay_ms: integer
   login_mode: string
   logout_mode: string
   access_expires_in: integer
   roles: {string: string}
end

return FakeSettings
