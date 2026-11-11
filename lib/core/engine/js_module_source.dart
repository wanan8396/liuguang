/// Prepare a *single-file* module for engines without an ES-module loader.
/// Token positions are tracked so comments, strings and regex literals are
/// never rewritten. This is deliberately not an import resolver or bundler.
String prepareSingleFileJs(String source) {
  final tokens = _tokens(source);
  final changes = <(int, int, String)>[];
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.depth != 0 || (i > 0 && tokens[i - 1].text == '.')) continue;
    if (token.text == 'import') {
      throw const FormatException('此平台需要单文件 JS；请先合并 import 依赖');
    }
    if (token.text != 'export' || i + 1 >= tokens.length) continue;
    final next = tokens[i + 1];
    if (next.text == 'default') {
      changes.add((token.start, next.end, 'globalThis.__lgDefault ='));
    } else if (next.text == '{') {
      var end = i + 2;
      while (end < tokens.length &&
          !(tokens[end].text == '}' && tokens[end].depth == 0)) {
        end++;
      }
      if (end >= tokens.length) {
        throw const FormatException('Invalid JS export list');
      }
      if (end + 1 < tokens.length && tokens[end + 1].text == 'from') {
        throw const FormatException('请先合并 JS re-export 依赖');
      }
      var replacement = '';
      for (var j = i + 2; j + 2 < end; j++) {
        if (tokens[j + 1].text == 'as' && tokens[j + 2].text == 'default') {
          replacement = 'globalThis.__lgDefault = ${tokens[j].text};';
        }
      }
      changes.add((token.start, tokens[end].end, replacement));
      i = end;
    } else if (next.text == '*') {
      throw const FormatException('请先合并 JS re-export 依赖');
    } else {
      changes.add((token.start, token.end, ''));
    }
  }
  final output = StringBuffer();
  var offset = 0;
  for (final change in changes) {
    output.write(source.substring(offset, change.$1));
    output.write(change.$3);
    offset = change.$2;
  }
  output.write(source.substring(offset));
  return output.toString();
}

class _Token {
  const _Token(this.text, this.start, this.end, this.depth);
  final String text;
  final int start, end, depth;
}

List<_Token> _tokens(String text) {
  final result = <_Token>[];
  final identifier = RegExp(r'[A-Za-z_$\u0080-\uffff]');
  final number = RegExp(r'[0-9]');
  var depth = 0;
  var expression = true;
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c.trim().isEmpty || c == '\ufeff') {
      i++;
      continue;
    }
    if (c == '/' && i + 1 < text.length && text[i + 1] == '/') {
      i += 2;
      while (i < text.length && text[i] != '\n' && text[i] != '\r') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < text.length && text[i + 1] == '*') {
      final end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 2;
      continue;
    }
    final start = i;
    if (c == '"' || c == "'" || c == '`') {
      i++;
      while (i < text.length) {
        if (text[i] == '\\') {
          i += 2;
          continue;
        }
        if (text[i++] == c) break;
      }
      if (i > text.length) i = text.length;
      result.add(_Token('<literal>', start, i, depth));
      expression = false;
      continue;
    }
    if (c == '/' && expression) {
      i++;
      var characterClass = false;
      while (i < text.length) {
        if (text[i] == '\\') {
          i += 2;
          continue;
        }
        if (text[i] == '[') characterClass = true;
        if (text[i] == ']') characterClass = false;
        if (text[i++] == '/' && !characterClass) break;
      }
      while (i < text.length && identifier.hasMatch(text[i])) {
        i++;
      }
      if (i > text.length) i = text.length;
      result.add(_Token('<literal>', start, i, depth));
      expression = false;
      continue;
    }
    if (identifier.hasMatch(c) || number.hasMatch(c)) {
      i++;
      while (i < text.length &&
          (identifier.hasMatch(text[i]) || number.hasMatch(text[i]))) {
        i++;
      }
      final value = text.substring(start, i);
      result.add(_Token(value, start, i, depth));
      expression = {
        'return',
        'throw',
        'case',
        'typeof',
        'void',
        'delete',
        'new',
        'yield',
        'await',
        'in',
        'of',
      }.contains(value);
      continue;
    }
    if (c == '}') depth--;
    result.add(_Token(c, i, i + 1, depth));
    if (c == '{') depth++;
    expression = !{')', ']', '}', '.'}.contains(c);
    i++;
  }
  return result;
}
