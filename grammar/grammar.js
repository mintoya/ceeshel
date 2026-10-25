const comma_list = $ => optional(seq(
  $._expression,
  repeat(seq(',', $._expression)),
  optional(','),
));

const binop = ($, level, left, operator, right) =>
  prec(level, seq(field('left', left), field('operator', operator), field('right', right)));

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
  ['_call' + s]: $ => choice($['_binary' + s], alias($['_call_op' + s], $.op)),
  // juxtaposition: `f a b` is `f (a b)`
  ['_call_op' + s]: $ => seq(field('left', $['_binary' + s]), field('right', $._call_n)),

  ['_binary' + s]: $ => prec('operator-name', choice(
    $['_add' + s],
    alias($['_cmp_op' + s], $.op),
    alias($['_infix_op' + s], $.op),
    ...Object.keys(isolated).map(name => alias($[name + s], $.op)),
  )),
  ['_cmp_op' + s]: $ => prec('operator', seq(field('left', $['_add' + s]),
    field('operator', choice(...cmp_operators)), field('right', $._add))),
  ['_infix_op' + s]: $ => prec('chain', seq(
    field('left', choice($['_post' + s], alias($['_infix_op' + s], $.op))),
    '<<', field('operator', $._expression), '>>',
    field('right', $._post),
  )),
  ...Object.fromEntries(Object.entries(isolated).map(([name, operator]) => [
    name + s,
    $ => binop($, 'chain', choice($['_post' + s], alias($[name + s], $.op)), operator, $._post),
  ])),

  ['_add' + s]: $ => prec('operator-name', choice($['_mul' + s], alias($['_add_op' + s], $.op))),
  ['_add_op' + s]: $ => binop($, 'add', $['_add' + s], choice('+', '-'), $._mul),
  ['_mul' + s]: $ => prec('operator-name', choice($['_post' + s], alias($['_mul_op' + s], $.op))),
  ['_mul_op' + s]: $ => binop($, 'mul', $['_mul' + s], choice('*', '/', '%'), $._post),

  // access and tight calls
  ['_post' + s]: $ => choice($['_primary' + s], alias($['_access_op' + s], $.op),
    alias($['_tight_op' + s], $.op), alias($._quote_op, $.op)),
  ['_access_op' + s]: $ => binop($, 'postfix', $['_post' + s], choice('.', ':'),
    choice($._primary, alias($._member_quote, $.op))),
  ['_tight_op' + s]: $ => prec('postfix', seq(field('left', $['_post' + s]), field('right', $._block_immediate))),
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
      alias($._assign, $.op),
      $.decl,
    ),
    _assign: $ => binop($, 'chain', $._pipe, '=', $._expression),
    // name ~ type | name ~ type ~ value | name ~ type = value | name ~~ value | name ~= value
    decl: $ => seq(
      field('name', $._pipe),
      '~',
      choice(
        field('type', $._pipe),
        seq(field('type', $._pipe), field('assignment_op', choice('~', '=')), field('value', $._expression)),
        seq(field('assignment_op', choice('~', '=')), field('value', $._expression)),
      ),
    ),

    _pipe: $ => choice($._call, alias($._pipe_op, $.op)),
    _pipe_op: $ => binop($, 'chain', $._pipe, '|>', $._call),

    ...operand_rules(''),
    ...operand_rules('_n'),

    // a quote mark against an operand is a prefix over its postfix chain:
    // '@fn[x] quotes the call. tree-sitter can't see that the two touch, so
    // `' a` with a space also highlights this way.
    _quote_op: $ => prec('quote', seq(field('left', alias($._quote_mark, $.id)), field('right', $._post))),
    _quote_mark: $ => choice('\'', '`', '\\', '..'),
    // after . or : a quote mark names the member: x.`(name)
    _member_quote: $ => prec('member-quote', seq(field('left', alias($._quote_mark, $.id)),
      field('right', choice($._primary, $._block_immediate)))),

    // an operator in operand position is a name: + ~~ ..., +[a, b], f +
    _operator_name: $ => prec('operator-name', choice(
      '+', '-', '*', '/', '%', '==', '!=', '<', '>', '<=', '>=', '<=>',
      'and', 'or', 'band', 'bor', 'bxor', 'shl', 'shr', 'xor', 'as',
    )),
    _primary: $ => choice($._primary_n, alias($._operator_name, $.id)),
    _primary_n: $ => choice($.id, $.string, $.number, $._block),

    _block: $ => choice($.bblock, $.ablock, $.pblock),
    bblock: $ => seq('{', repeat($._statement), optional($._expression), '}'),
    ablock: $ => seq('[', comma_list($), ']'),
    pblock: $ => seq('(', optional($._expression), ')'),

    _block_immediate: $ => choice(
      alias($._bblock_immediate, $.bblock),
      alias($._ablock_immediate, $.ablock),
      alias($._pblock_immediate, $.pblock),
    ),
    _bblock_immediate: $ => seq(token.immediate('{'), repeat($._statement), optional($._expression), '}'),
    _ablock_immediate: $ => seq(token.immediate('['), comma_list($), ']'),
    _pblock_immediate: $ => seq(token.immediate('('), optional($._expression), ')'),

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
