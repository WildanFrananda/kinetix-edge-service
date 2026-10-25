local record sha256
   record Digest
      update: function(Digest, string): boolean
      final: function(Digest): string
   end

   new: function(): Digest
end

return sha256
