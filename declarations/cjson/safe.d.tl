local record safe
   type Leaf = string | number | boolean
   type Object = {string: Leaf}
   type Field = string | number | boolean | Object
   type Document = {string: Field}

   decode: function(string): Document | Leaf, string
   encode: function<T>(T): string, string
   encode_escape_forward_slash: function(boolean)
   null: userdata
end

return safe
