local record Mutation
   id: string
   check: string
   file: string
   old: string
   new: string
   unit: {string}
   integration: {string}
end

return Mutation
