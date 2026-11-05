/// Minimal arithmetic evaluator for summary/cell formulas.
/// Supports: numbers, `7%` postfix, identifiers resolved from [env],
/// `+ - * /`, parentheses, unary minus. Leading `=` is optional.
/// Returns null on any parse/eval error.
double? evalFormula(String src, Map<String, double> env) {
  var s = src.trim();
  if (s.startsWith('=')) s = s.substring(1);
  if (s.isEmpty) return null;
  try {
    final p = _Parser(s, env);
    final v = p.expr();
    p.skipWs();
    return p.atEnd ? v : null;
  } catch (_) {
    return null;
  }
}

class _Parser {
  _Parser(this.s, this.env);
  final String s;
  final Map<String, double> env;
  int i = 0;

  bool get atEnd => i >= s.length;
  String get _peek => atEnd ? '' : s[i];
  void skipWs() {
    while (!atEnd && s[i] == ' ') {
      i++;
    }
  }

  double expr() {
    var v = term();
    while (true) {
      skipWs();
      if (_peek == '+') {
        i++;
        v += term();
      } else if (_peek == '-') {
        i++;
        v -= term();
      } else {
        return v;
      }
    }
  }

  double term() {
    var v = factor();
    while (true) {
      skipWs();
      if (_peek == '*') {
        i++;
        v *= factor();
      } else if (_peek == '/') {
        i++;
        v /= factor();
      } else {
        return v;
      }
    }
  }

  double factor() {
    skipWs();
    if (_peek == '-') {
      i++;
      return -factor();
    }
    if (_peek == '+') {
      i++;
      return factor();
    }
    double v;
    if (_peek == '(') {
      i++;
      v = expr();
      skipWs();
      if (_peek != ')') throw const FormatException('missing )');
      i++;
    } else if (_isDigit(_peek) || _peek == '.') {
      v = _number();
    } else if (_isAlpha(_peek)) {
      final id = _ident().toUpperCase();
      final e = env[id];
      if (e == null) throw FormatException('unknown id: $id');
      v = e;
    } else {
      throw FormatException('unexpected: $_peek');
    }
    skipWs();
    if (_peek == '%') {
      i++;
      v /= 100;
    }
    return v;
  }

  double _number() {
    final start = i;
    while (!atEnd && (_isDigit(s[i]) || s[i] == '.')) {
      i++;
    }
    return double.parse(s.substring(start, i));
  }

  String _ident() {
    final start = i;
    while (!atEnd && (_isAlpha(s[i]) || _isDigit(s[i]))) {
      i++;
    }
    return s.substring(start, i);
  }

  static bool _isDigit(String c) =>
      c.isNotEmpty && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  static bool _isAlpha(String c) =>
      c.isNotEmpty &&
      (((c.codeUnitAt(0) | 32) >= 97 && (c.codeUnitAt(0) | 32) <= 122) ||
          c == '_');
}
