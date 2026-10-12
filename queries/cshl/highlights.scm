(comment) @comment
(string) @string
(number) @number
(id) @variable

((id) @function.builtin
  (#lua-match? @function.builtin "^@"))

(decl name: (id) @variable)
(op operator: "." right: (id) @variable.member)
(op operator: ":" right: (id) @function.method)
(op left: (id) @function.call
  !operator)

["as" "and" "or" "xor" "band" "bor" "bxor" "shl" "shr"] @keyword.operator
["." ":" "*" "/" "%" "+" "-" "<" ">" "<=" ">=" "==" "!=" "<=>" "|>" "=" "~"] @operator
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";"] @punctuation.delimiter

((id) @operator
  (#any-of? @operator "'" "`"))
