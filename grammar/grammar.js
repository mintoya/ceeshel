// For highlighting only; the compiler has its own parser. The tree has four
// kinds of node, like the AST:
//   atoms  id, number, string
//   list   [a, b] and (a, b): the same thing
//   block  {a; b}
//   call   everything that applies something, head in `function`:
//            f[a, b], f(a, b), f x, a + b, a.b, a:m, 'x, a <<g>> b
//          and declarations, x ~T = v, whose name, type and value are
//          fields so they can be colored.
// (x) groups: it is just x. [x] never groups: it is a one-item list, as is
// (x,).

// arguments of a tight call: f[a, b], f(a, b), f()
const arg_list = $ => optional(seq(
  field('argument', $._expression),
  repeat(seq(',', field('argument', $._expression))),
  optional(','),
));

// a () list is empty, has a comma, or has two or more items: (x) groups
const paren_items = $ => optional(choice(
  seq($._expression, ','),
  seq($._expression, repeat1(seq(',', $._expression)), optional(',')),
));
// a [] list is any number of items
const bracket_items = $ => optional(seq(
  $._expression,
  repeat(seq(',', $._expression)),
  optional(','),
));

const binop = ($, level, left, operator, right) =>
  prec(level, seq(field('argument', left), field('function', operator), field('argument', right)));

// Operators with no precedence relation to anything else. Each one chains
// with itself (left-associative); mixing two of them, or one with
// arithmetic or comparison, needs parentheses.
const isolated = {
  _and_op: 'and',
  _or_op: 'or',
  _xor_op: 'xor',
  _band_op: 'band',
  _bor_op: 'bor',
  _bxor_op: 'bxor',
  _shl_op: 'shl',
  _shr_op: 'shr',
  _as_op: 'as',
};

const cmp_operators = ['<', '>', '<=', '>=', '==', '!=', '<=>'];

// The operand levels, twice: suffix '' may start with an operator used as a
// name (+[a, b]), suffix '_n' may not. The argument of juxtaposition is an
// '_n' operand, so `a < b < c` is an error rather than `(a < b) (< c)`.
const operand_rules = s => ({
  ['_call' + s]: $ => choice($['_binary' + s], alias($['_juxt' + s], $.call)),
  // juxtaposition: `f a b` is `f (a b)`
  ['_juxt' + s]: $ => seq(field('function', $['_binary' + s]), field('argument', $._call_n)),

  ['_binary' + s]: $ => prec('operator-name', choice(
    $['_add' + s],
    alias($['_cmp_op' + s], $.call),
    alias($['_infix_op' + s], $.call),
    ...Object.keys(isolated).map(name => alias($[name + s], $.call)),
  )),
  ['_cmp_op' + s]: $ => prec('operator', seq(field('argument', $['_add' + s]),
    field('function', choice(...cmp_operators)), field('argument', $._add))),
  ['_infix_op' + s]: $ => prec('chain', seq(
    field('argument', choice($['_post' + s], alias($['_infix_op' + s], $.call))),
    '<<', field('function', $._expression), '>>',
    field('argument', $._post),
  )),
  ...Object.fromEntries(Object.entries(isolated).map(([name, operator]) => [
    name + s,
    $ => binop($, 'chain', choice($['_post' + s], alias($[name + s], $.call)), operator, $._post),
  ])),

  ['_add' + s]: $ => prec('operator-name', choice($['_mul' + s], alias($['_add_op' + s], $.call))),
  ['_add_op' + s]: $ => binop($, 'add', $['_add' + s], choice('+', '-'), $._mul),
  ['_mul' + s]: $ => prec('operator-name', choice($['_post' + s], alias($['_mul_op' + s], $.call))),
  ['_mul_op' + s]: $ => binop($, 'mul', $['_mul' + s], choice('*', '/', '%'), $._post),

  // access and tight calls
  ['_post' + s]: $ => choice($['_primary' + s], alias($['_access_op' + s], $.call),
    alias($['_tight_op' + s], $.call), alias($._quote_op, $.call)),
  ['_access_op' + s]: $ => binop($, 'postfix', $['_post' + s], choice('.', ':'),
    choice($._primary, alias($._member_quote, $.call))),
  // f[a, b], f(a, b) and f{...}: the head touches the brackets
  ['_tight_op' + s]: $ => prec('postfix', seq(field('function', $['_post' + s]), choice(
    seq(token.immediate('['), arg_list($), ']'),
    seq(token.immediate('('), arg_list($), ')'),
    field('argument', alias($._block_immediate, $.block)),
  ))),
});

module.exports = grammar({
  name: 'cshl',
  extras: $ => [
    /\s+/,
    $.comment,
  ],
  // operator words (and, or, as, ...) are keywords, never identifiers
  word: $ => $._word,
  reserved: {
    global: $ => ['and', 'or', 'xor', 'band', 'bor', 'bxor', 'shl', 'shr', 'as'],
  },
  // only to settle quote marks: postfix binds inside a quote, and a mark
  // followed by an operand quotes it rather than standing alone
  precedences: $ => [['member-quote', 'postfix', 'quote', 'mark'], ['mul', 'add', 'chain', 'operator', 'operator-name']],
  // Precedence is a partial order, tightest first:
  //   postfix (. : tight call)
  //   * / %  >  + -  >  comparison (does not chain)
  //   and, or, xor, band, bor, bxor, shl, shr, as, <<f>>: unrelated
  //   juxtaposition  >  |>  >  = and ~
  rules: {
    // `;`-separated, empty statements allowed, final `;` optional
    program: $ => seq(repeat($._statement), optional($._expression)),
    empty_statement: $ => ';',
    _statement: $ => choice(
      seq($._expression, ';'),
      $.empty_statement
    ),

    _expression: $ => choice(
      $._pipe,
      alias($._assign, $.call),
      alias($._decl, $.call),
    ),
    _assign: $ => binop($, 'chain', $._pipe, '=', $._expression),
    // x ~T, x ~T ~ v, x ~T = v, x ~~ v, x ~= v: a call of ~, ~~ or ~=
    _decl: $ => seq(
      field('name', $._pipe),
      field('function', '~'),
      choice(
        field('type', $._pipe),
        seq(field('type', $._pipe), field('function', choice('~', '=')), field('value', $._expression)),
        seq(field('function', choice('~', '=')), field('value', $._expression)),
      ),
    ),

    _pipe: $ => choice($._call, alias($._pipe_op, $.call)),
    _pipe_op: $ => binop($, 'chain', $._pipe, '|>', $._call),

    ...operand_rules(''),
    ...operand_rules('_n'),

    // a quote mark against an operand is a prefix over its postfix chain:
    // '@fn[x] quotes the call. tree-sitter can't see that the two touch, so
    // `' a` with a space also highlights this way.
    _quote_op: $ => prec('quote', seq(field('function', alias($._quote_mark, $.id)), field('argument', $._post))),
    _quote_mark: $ => choice('\'', '`', '\\', '..'),
    // after . or : a quote mark names the member: x.`(name)
    _member_quote: $ => prec('member-quote', seq(field('function', alias($._quote_mark, $.id)),
      field('argument', choice($._primary, $._group_immediate)))),

    // an operator in operand position is a name: + ~~ ..., +[a, b], f +
    _operator_name: $ => prec('operator-name', choice(
      '+', '-', '*', '/', '%', '==', '!=', '<', '>', '<=', '>=', '<=>',
      'and', 'or', 'band', 'bor', 'bxor', 'shl', 'shr', 'xor', 'as',
    )),
    _primary: $ => choice($._primary_n, alias($._operator_name, $.id)),
    _primary_n: $ => choice($.id, $.string, $.number, $._group, $.list, $.block),

    // (x): just x
    _group: $ => seq('(', $._expression, ')'),
    _group_immediate: $ => seq(token.immediate('('), $._expression, ')'),
    list: $ => choice(seq('(', paren_items($), ')'), seq('[', bracket_items($), ']')),
    block: $ => seq('{', repeat($._statement), optional($._expression), '}'),
    _block_immediate: $ => seq(token.immediate('{'), repeat($._statement), optional($._expression), '}'),

    id: $ => choice($._word, prec('mark', $._quote_mark)),
    _word: $ => /@?[a-zA-Z_\$\?\!\#][a-zA-Z0-9_\$\?\!\#]*/,
    string: $ => /"([^"\\]|\\.)*"/,
    number: $ => choice(
      /-?[0-9][0-9_]*(\.[0-9][0-9_]*)?/,
      /-?0x[0-9a-fA-F]+/,
      /-?0b[01]+/
    ),

    // a #lang line is a comment too: the file is also a Racket module
    comment: $ => token(choice(
      seq('//', /.*/),
      seq('#lang', /.*/),
      seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/')
    ))
  }
});
