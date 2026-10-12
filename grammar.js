module.exports = grammar({
  name: 'cshl',
  extras: $ => [
    /\s+/,
    $.comment,
  ],
  conflicts: $ => [
    [$._expression, $.decl],
    [$.nblock],
  ],
  precedences: $ => [
    [
      'access',
      'block-call',  // tight call
      'type',
      'mul',
      'add',
      'cmp',
      'bit',
      'nblock',      
      'call',        // loose call
      'pipe',
      'decl',
      'assign'
    ]
  ],
  rules: {
    program: $ => repeat($._statement),
    empty_statement: $=>';',
    _statement: $ => choice(
      seq($._any_expression, ';'),
      $.empty_statement
    ),

    _any_expression: $ => prec.right('call', choice(
      $._expression,
      $.nblock
    )),

    _expression: $ => choice(
      $.id,
      $.string,
      $.number,
      $.decl,
      $._block,
      $.op
    ),
    op: $ => choice(
      prec.left('block-call', seq(field('left', $._expression), field('right', $._block_immediate))),
      

      prec.right('call', seq(field('left', $._expression), field('right', $._any_expression))), 

      
      
      prec.left('access', seq(field('left', $._expression), field('operator', '.'), field('right', $._expression))),
      prec.left('access', seq(field('left', $._expression), field('operator', ':'), field('right', $._expression))),
      prec.left('type', seq(field('left', $._expression), field('operator', choice('as')), field('right', $._expression))),
      prec.left('mul', seq(field('left', $._expression), field('operator', choice('*', '/', '%')), field('right', $._expression))),
      prec.left('add', seq(field('left', $._expression), field('operator', choice('+', '-')), field('right', $._expression))),
      prec.left('bit', seq(field('left', $._expression), field('operator', choice('and', 'or', 'xor', 'band', 'bor', 'shr', 'shl', 'bxor')), field('right', $._expression))),
      prec.dynamic(1, prec.left('cmp', seq(field('left', $._expression), field('operator', choice('<', '>', '<=', '>=', '==', '!=', '<=>')), field('right', $._expression)))),
      prec.left('pipe', seq(field('left', $._expression), field('operator', '|>'), field('right', $._expression))),
      prec.right('assign', seq(field('left', $._expression), field('operator', '='), field('right', $._expression))),
    ),
    decl: $ => prec.right('decl', choice(
      prec.dynamic(3, seq(
        field('name', choice($.id, $.op)),
        '~',
        field('type', $._expression),
        field('assignment_op', choice('~', '=')),
        field('value', $._expression)
      )),
      prec.dynamic(2, seq(
        field('name', choice($.id, $.op)),
        '~',
        field('assignment_op', choice('~', '=')),
        field('value', $._expression)
      )),
      prec.dynamic(1, seq(
        field('name', choice($.id, $.op)),
        '~',
        field('type', $._expression)
      ))
    )),

    _block: $ => choice($.bblock, $.ablock, $.pblock),
    
    _comma_list: $ => seq($._expression, optional(seq(',', optional($._comma_list)))),
    bblock: $ => prec(2,seq('{', repeat($._statement), '}')),
    ablock: $ => prec(2,seq('[',optional($._comma_list),']')),
    pblock: $ => prec(2,seq('(',optional($._comma_list),')')),
    
    _nblock_continuation: $ => prec('nblock', seq(',', $._expression)),

    nblock: $ => prec('nblock', 
      seq($._expression, repeat1($._nblock_continuation))
    ),

    _block_immediate: $ => choice(
      $._bblock_immediate,
      $._ablock_immediate,
      $._pblock_immediate,
    ),
    
    _bblock_immediate: $ => alias($.__bblock_immediate, $.bblock),
    _ablock_immediate: $ => alias($.__ablock_immediate, $.ablock),
    _pblock_immediate: $ => alias($.__pblock_immediate, $.pblock),
    __bblock_immediate: $ => seq( token.immediate('{'), repeat($._statement), '}'),
    __ablock_immediate: $ => seq( token.immediate('['), optional($._comma_list),']'),
    __pblock_immediate: $ => seq( token.immediate('('), optional($._comma_list),')'),

    id: $ => choice(/@?[a-zA-Z_\$\?\!\#][a-zA-Z0-9_\$\?\!\#]*/ , '\'','`'),
    string: $ => /"([^"\\]|\\.)*"/,
    number: $ => choice(
      /-[0-9]+/,
      /[0-9]+/,
      /0x[0-9a-fA-F]+/,
      /0b[01]+/
    ),
    
    comment: $ => token(choice(
      seq('//', /.*/),
      seq( '/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/')
    ))
  }
});
