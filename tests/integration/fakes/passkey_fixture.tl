local record passkey_fixture
   credential_id: string
   unknown_credential_id: string
   lab_rp_id: string
end

passkey_fixture.credential_id = "Y3JlZGVudGlhbC0xMDc"

passkey_fixture.unknown_credential_id = "Y3JlZGVudGlhbC05OTk"

passkey_fixture.lab_rp_id = "backoffice.localhost"

function passkey_fixture.creation_options(rp_id: string): string
   return "{\"challengeId\":\"7d8e3c1a-5b2f-4a61-9c3e-2f1b0a9d8c7e\",\"options\":"
      .. "{\"challenge\":\"fake-passkey-creation-challenge\",\"rp\":{\"name\":\"Kinetix Backoffice\","
      .. "\"id\":\"" .. rp_id .. "\"},\"user\":{\"id\":\"cHJuX2Zha2VfMTA1\",\"name\":\"admin-2fa\","
      .. "\"displayName\":\"admin-2fa\"},\"pubKeyCredParams\":[{\"alg\":-7,\"type\":\"public-key\"},"
      .. "{\"alg\":-257,\"type\":\"public-key\"}],\"timeout\":300000,\"attestation\":\"none\","
      .. "\"excludeCredentials\":[],\"authenticatorSelection\":{\"residentKey\":\"preferred\","
      .. "\"userVerification\":\"required\"}}}"
end

function passkey_fixture.view(rp_id: string): string
   return "{\"id\":\"0f6c2d4e-8a1b-4c3d-9e5f-6a7b8c9d0e1f\",\"credentialId\":\"" .. passkey_fixture.credential_id
      .. "\",\"rpId\":\"" .. rp_id .. "\",\"name\":\"Laptop\",\"createdAt\":\"2026-10-29T08:00:00.000Z\","
      .. "\"lastUsedAt\":null,\"deviceType\":\"multiDevice\",\"backedUp\":true}"
end

function passkey_fixture.options(challenge: string, rp_id: string): string
   return "{\"options\":{\"challenge\":\"" .. challenge .. "\",\"timeout\":120000,"
      .. "\"rpId\":\"" .. rp_id .. "\",\"allowCredentials\":[{\"id\":\"" .. passkey_fixture.credential_id
      .. "\",\"type\":\"public-key\",\"transports\":[\"internal\",\"hybrid\"]},"
      .. "{\"id\":\"Y3JlZGVudGlhbC0xMDgt\",\"type\":\"public-key\",\"transports\":[]}],"
      .. "\"userVerification\":\"required\"}}"
end

function passkey_fixture.credential(id: string): string
   return "{\"id\":\"" .. id .. "\",\"rawId\":\"" .. id .. "\",\"type\":\"public-key\","
      .. "\"response\":{\"clientDataJSON\":\"eyJ0eXBlIjoid2ViYXV0aG4uZ2V0In0\","
      .. "\"authenticatorData\":\"SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MFAAAAAQ\","
      .. "\"signature\":\"fake-passkey-signature\",\"userHandle\":\"cHJuX2Zha2VfMTA3\"},"
      .. "\"clientExtensionResults\":{},\"authenticatorAttachment\":\"platform\"}"
end

return passkey_fixture
