; Neovim: patterns later in the file override earlier ones for the same node,
; so general captures come first and specific ones after.

; Primitives
(string) @string
(comment) @comment
(number) @number

; Fallback for every identifier
(id) @variable

((id) @keyword
 (#any-of? @keyword "return" "defer" "break" "continue"))

; `_` is the value piped in by |>
((id) @variable.builtin
 (#eq? @variable.builtin "_"))

; Declarations: x ~T = v
(call type: (id) @type)
(call name: (id) @variable.builtin)

; Calls: the head of f[x], f(x) and f x
(call
  function: (id) @function.call)

; Member access and methods: a.b, a:m
(call
  function: "."
  argument: (id) @variable.member .)
(call
  function: ":"
  argument: (id) @function.method .)

; Builtins, after calls so @fn[...] keeps its own color
((id) @function.macro
 (#lua-match? @function.macro "^@"))

; Quote ' unquote ` escape \ splice ..
((id) @punctuation.special
 (#any-of? @punctuation.special "'" "`" "\\" ".."))

; Operators
[
  "as"
  "~" "=" "+" "-" "*" "/" "%" "|>"
  "<" ">" "<=" ">=" "==" "!=" "<=>"
  "and" "or" "xor" "band" "bor" "bxor" "shr" "shl"
  "<<" ">>"
] @operator

; Delimiters and brackets
[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
[ ";" "," "." ":" ] @punctuation.delimiter
