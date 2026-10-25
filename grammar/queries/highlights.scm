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

; Declarations
(decl type: (id) @type)
(decl name: (id) @variable.builtin)

; Calls: tight `f(x)` and juxtaposition `f x` are ops without an operator
(op
  left: (id) @function.call
  !operator)

; Member access and methods
(op
  operator: "."
  right: (id) @variable.member)
(op
  operator: ":"
  right: (id) @function.method)

; a <<f>> b: the function between the brackets
(op
  "<<"
  operator: (id) @function.call)
(op
  "<<"
  operator: (op
    operator: [":" "."]
    right: (id) @function.call))

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
