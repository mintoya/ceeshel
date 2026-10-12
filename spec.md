# CSHL specification

CSHL has a small core, its syntax (§1) and a fixed set of `@` builtins (§3).
Everything else is library code.

- `fn`, `if`, `while`, `slice`, `iterator`, `enum_tag`, the integer aliases
  (`i8`..`i64`, `u8`..`u64`), and `true`/`false`/`null`/`not` are **ordinary CSHL
  definitions** in the library, not syntax or builtins.

## 1. Syntax

### Tokens

| Class | Spelling |
| --- | --- |
| identifier | `@?[A-Za-z_$?!#][A-Za-z0-9_$?!#]*` |
| number | `-?[0-9]+`, `0x…`, `0b…` |
| string | `"…"` with `\` escapes; `"yo"` is `@arr(2, @sint 8)` |
| comment | `// …` and `/* … */` |

Whitespace is insignificant except where it separates a callee from a block.

### Grammar

```
program    = { statement }
statement  = ";" | expression ";"
expression = id | string | number | decl | block | op
decl       = name "~" ( type [ ("~" | "=") value ]
                      | ("~" | "=") value )
block      = "{" { statement } "}"                 bblock: yields last expression
           | "[" [ expr { "," expr } [","] ] "]"   ablock: comma list
           | "(" [ expr { "," expr } [","] ] ")"   pblock: comma list
```

`name` is an identifier, or an operator spelling supplied by `@id("…")`.

### Operators

Tightest to loosest:

| # | Operators | Notes |
| --- | --- | --- |
| 1 | `.` `:` | member access / method call (§Methods and pipes) |
| 2 | tight call | `f{…}` `f[…]` `f(…)` — no space before the block |
| 3 | `as` | cast |
| 4 | `*` `/` `%` | |
| 5 | `+` `-` | |
| 6 | `<` `>` `<=` `>=` `==` `!=` `<==>` | comparisons |
| 7 | `and` `or` `band` `bor` `bxor` `shl` `shr` | `and`/`or` short-circuit |
| 8 | loose call | juxtaposition: `f x`, `f (x, y)` |
| 9 | `\|>` | pipe (§Methods and pipes) |
| 10 | `~` | declaration |
| 11 | `=` | assignment (loosest) |

Comparisons bind tighter than `and`/`or`/bitwise: `a == b and c` is `(a == b) and c`.

### Calls

Juxtaposition is a call, and spacing selects which:

- `f(x)` — tight call; the parenthesized block is the argument list.
- `f[x]` — the whole bracketed block is one AST argument.
- `f (x)` — loose call; the whole parenthesized block is **one** argument.
- `f x` — one argument.

Blocks chain: `f{…}[…](…)` calls through each in turn.

### Methods and pipes

- `receiver:method(args)` calls the function `method` found in the receiver's
  type namespace, passing the receiver as the first argument. The receiver is
  evaluated **once** and passed as a place, so a `@refT(Self)` parameter aliases
  it. (The method *name* is resolved against `@typeof(receiver)`; the receiver
  expression itself is not re-evaluated.)
- `a |> body` evaluates `a` and binds it to `_` in `body`. A place or reference
  operand binds `_` as a reference to it, so `_ = v` writes through; a
  compile-time value binds `_` to the value. Pipes chain left to right.

## 2. Declarations

All values are zero-initialized. `x ~ T = v` is mutable, `x ~ T ~ v` constant,
`x ~ T` declares a mutable value of type `T`, and `x ~= v` infers the type.
A constant may hold a const-qualified **runtime** value: `a ~~ f()`
does not force the call to compile time. In an aggregate, `name ~~ value` is a
compile-time namespace member taking no runtime storage; `name ~ T` is a runtime
member.

A block yields its last expression (`{5;}` is `5`, `{;}` is void) and may yield a
reference, so `{ @ref x; } = 17` writes to `x`. Parenthesized and bracketed lists
are syntax, not runtime tuples or aggregates: `[1,2]`, `[]`, `[x = 1]`, and `(1,2)`
as a value are rejected.

## 3. Builtins

### Types

| Builtin | Result |
| --- | --- |
| `@void()` `@bool()` `@int()` `@type()` `@ast()` `@inlineast()` `@any()` | primitive type values |
| `@sint N` `@uint N` | N-bit signed / unsigned integer, `N` in `1..2^20` |
| `@arr(N, T)` (alias `@arrof`) | `N`-element array |
| `@ptr(T)` (alias `@ptrof`) | pointer to `T` |
| `@refT(T)` (alias `@reft`) | reference to `T` |
| `@const T` `@comptime T` `@volatile T` | qualified `T` |
| `@fnptr((T…), R)` | runtime function pointer |
| `@struct {…}` `@union {…}` | aggregate types |
| `@this()` | the enclosing aggregate |
| `@fn(params, R, body)` | function; a parameter is `x ~T` or a bare type |

### References, queries, layout

| Builtin | Result |
| --- | --- |
| `@ref x` | reference to the place `x` |
| `@where x` | pointer to `x` |
| `@at p` | a reference to the `T` at the address in `p` (an assignable place); rejected when `p` is not a pointer |
| `@typeof x` | `x`'s type with expression-reference, `const`, and `comptime` stripped; `volatile` kept |
| `@isref x` `@isconst x` `@iscomptime x` | compile-time boolean about the expression |
| `@sizeof T` `@alignof T` | layout of a **type value** (`@sizeof(@typeof x)`, not `@sizeof(x)`) |
| `@offsetof(T, m)` | member offset; `m` is an identifier, not an expression |

### Compile time and metaprogramming

| Builtin | Result |
| --- | --- |
| `@qot expr` / `@uqot ast` | quote syntax / evaluate or insert AST; also written `'expr` / `` `ast `` |
| `@ast_op(spelling, l, r)` | operator node |
| `@gensym(prefix)` / `@id(string)` | fresh identifier / identifier by spelling |
| `@apply(f, list)` / `@splice` | map an AST-returning `f` over list children / insert children |
| `@typeinfo(T)` | reflection value (§Reflection) |
| `@rawget(v, name)` | read a member without running a `.` overload |
| `@specialize(call)` | the specialization a call selects, without executing it |
| `@compiles(expr)` | whether `expr` is valid in the current scope (side effects such as environment writes are not undone) |
| `@returntype()` / `@returnvalue()` | enclosing return type / captured return value in `defer` |
| `@compileError(…)` / `@error(…)` | fail compilation |

### Control flow

| Builtin | Result |
| --- | --- |
| `@if(cond, then[, else])` | runtime branch |
| `@cif(cond, then[, else])` | compile-time branch; only the selected branch is produced |
| `@loop body` / `@cwhile(cond, body)` | runtime loop / compile-time loop while `cond` is true |
| `break()` `continue()` | control the nearest runtime loop |
| `return v` / `return()` | leave the function |
| `defer body` | run on scope exit |

### Modules and environment

| Builtin | Result |
| --- | --- |
| `@import(path)` | load a file and yield its result (a file exports by ending in a struct) |
| `@path()` / `@path(name)` | current source / a name resolved relative to it |
| `@using(struct)` | introduce a namespace's members into the scope |
| `@unbind(name)` | drop a current-scope binding |
| `@_Env_set(keys…, value)` / `@_Env_get(keys…)` | compilation-wide compile-time tree |

### C integration

| Builtin | Result |
| --- | --- |
| `@cinclude(header)` | include in the generated prologue (rejected inside a function) |
| `@cout(string)` | insert C verbatim; parameters are `arg0`, `arg1`, … |
| `@ctype(name)` | external C type with no CSHL representation |

## 4. Semantics

### Integers

A literal (`5`) has type `@int()`: compile-time, arbitrary precision, zero
storage; compile-time math stays compile-time. A literal mixed with a runtime
integer adopts the runtime type — the **wider** operand wins, and at equal width a
signed/unsigned mix is unsigned.

Storage rounds the declared width up to whole bytes, with alignment equal to that
byte count. Fixed-width arithmetic keeps only the declared bits: unsigned wraps,
signed reads the top bit as sign; assigning an out-of-range literal truncates.
Widening casts preserve value, narrowing takes low bits and reinterprets the sign.
Division truncates toward zero; signed `shr` sign-extends.

### Types

Types are values (`@type()`), and constructors may use earlier compile-time
arguments in later ones. Types compare with `==`/`!=`; comparing a type with a
number or ordering with `<` is rejected. `@volatile(T)` has the same size and
alignment as `T` but is a distinct type, including under pointers.

### Places, references, pointers

A variable expression is a place; `@ref`, `@where`, `@at` move between places,
references, and pointers. Field and array-element access is addressable: writing
one copies into it and does not alias the source, while reference members can hold
aliases that survive a struct copy. Piping a reference place writes through it.
Explicit `as` converts between pointer types.

### Aggregates and layout

- `@struct`: runtime members plus compile-time namespace members.
- `@union`: runtime members all at offset 0; member initializers rejected.
- `@arr(N, T)`: fixed length, `a[i]` access, zero length allowed.
- `@sizeof`/`@alignof`/`@offsetof` inspect layout; a struct of only typed
  constants has size zero.

### Functions and overloads

`@fn(parameters, return_type, body)`. Calls check arity and coerce arguments.
Return types may depend on compile-time parameters. Functions keep their defining
block's compile-time names but cannot capture a caller's runtime frame. Runtime
recursion and compile-time recursion (`@cif`) both work. `@fnptr` rejects AST,
`any`, `comptime`, and compile-time-integer parameters. `@specialize(call)` binds
the compile-time arguments, drops them from the signature, and returns the
remaining function without executing runtime arguments.

A parameter may depend on an earlier compile-time parameter, as in
`@fn(( x~int, v~@sint(x)),(@sint(x)))`. Until `x` is known the dependent slot has no
standalone type, so such a generic has no signature of its own; its
un-specialized form is only expressible as `(int, any) any`, and `@fnptr` cannot
name it (it rejects compile-time parameters). Each call or `@specialize` fixes
`x` and resolves the slot — `x = 32` gives `@fnptr (i32) i32`.

Overloads are namespace functions named with `@id("operator")`:

- Comparison overloads: only `>`, `==`, `<==>` may be declared. `<` reverses `>`,
  `<=` negates `>`, `>=` negates reverse `>`, `!=` negates `==`. With no `>`/`==`,
  comparisons use the sign of `<==>`.
- `band` `bor` `bxor` `shl` `shr` cannot be overloaded.
- Return-type rules: `==`/`>` must return `@bool`, `<==>` must return `@sint 8`,
  and `as` must return exactly the requested type. A mismatch is
  `OVERLOAD_RETURN_TYPE`, and no coercion repairs it.
- `as` and comparison overloads cannot be `inline` or `any`; `as` also cannot take
  AST operands.
- `=` and `as` overloads provide coercion for assignment, initialized declarations,
  arguments, returns, and explicit casts. The destination type's `=` overload
  takes precedence over the source type's `as` overload. `=` overloads may take
  AST operands and return `@inlineast()`, expanded at the coercion site; the result
  is discarded.
- `.` is overloadable too: its overload receives the receiver and the member name
  as an `ast` (read the real member with `@rawget`).
- Without an overload, `as` is a builtin cast.

### Control flow, defer

`break`/`continue` target the nearest local runtime loop; loop bindings do not
escape. `@cwhile(cond, body)` repeatedly evaluates its compile-time condition and
analyzes the body while it is true. Inline expansion can retarget a caller's
runtime loop, an ordinary call cannot.

`defer` runs on scope exit (including `return` and loop control), most recent
first. It keeps the bindings it needs, sees the return value through
`@returnvalue()` (mutating the source does not change the captured value), and
cannot itself return or control an enclosing loop; `@returnvalue()` outside
deferred code is rejected.

### AST metaprogramming

An `ast` parameter receives syntax unevaluated. `@ast()` values stay data, while
`@inlineast()` values expand at the call site, where names resolve in the caller
and generated `return`s affect the caller.

`'expr` is an alias for `@qot expr` (quote), and `` `ast `` for `@uqot ast`
(unquote); both take a single operand.

Inspection probes are `.id` `.op` `.decl` `.ablock` `.pblock`; operator nodes
expose `.opleft`/`.opright`, and `."+"` selects by spelling; a non-match is an
empty AST. Lists index by zero and slice half-open (`ast[start,end]`), preserving
the bracket kind, with `0 <= start <= end <= length`. A function returning `ast`,
`inlineast`, or a type cannot depend on runtime arguments
(`COMPTIME_RETURN_RUNTIME_ARGUMENT`).

### Reflection

`@typeinfo(T)` yields false for views that do not match, and:

| Access | Result |
| --- | --- |
| `.comptime` | whether the inspected type is compile-time |
| `.array.len` / `.array.elem` | element count / element type |
| `.struct.members.len` / `.struct.members[i].name` / `.struct.members[i].type` | runtime member schema |
| `.struct.namespace.fn.0` / `.fn.1` | enclosing function / specialization identity |
| `.fn.0` | inspected function identity |

Struct member reflection omits namespace members and preserves reference member
types; indices must be a single in-bounds compile-time integer. Asking a struct
namespace for `.fn` outside a function is `NAMESPACE_HAS_NO_FUNCTION`.

### Modules and environment

`@import(path)` yields a file's result `@using` introduces those members and rejects
a non-struct or duplicate name; introduced names do not escape a block. `@path(name)`
resolves relative to the source, normalizing `.`/`..`. `@unbind` removes only a
current-scope binding. `@_Env_set`/`@_Env_get` are a compilation-wide compile-time
tree, shared with imports and fresh per compilation; missing paths, including a
parent that only has children, are rejected.

### C integration

Programs compile to standard C99 with no extensions. `@cout` text is the
program's responsibility.
