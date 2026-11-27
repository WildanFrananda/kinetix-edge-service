local record KillSwitchState
   feature: string
   enabled: boolean
   reason: string
   messageKey: string
   retryAfter: integer
   updatedAt: string
   updatedBy: string
   expiresAt: string
end

return KillSwitchState
