import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/engine/js_module_source.dart';

void main() {
  test('export in comments does not steal the actual module export', () {
    const input =
        '// export default example\n/* export default x */\nexport default {home(){return {list:[]}}};';
    final output = prepareSingleFileJs(input);
    expect(
      output,
      startsWith('// export default example\n/* export default x */'),
    );
    expect(output, contains('globalThis.__lgDefault = {home()'));
  });
  test(
    'strings templates regex literals and object property names are retained',
    () {
      const prefix = r'''const a="export default x";const b='import x';
const c=`export default y`;const re=/export default [a-z]/g;
const object={export:'value',import:'value'};object.export;object.import;
''';
      final output = prepareSingleFileJs('${prefix}export default object;');
      expect(output, startsWith(prefix));
      expect(output, endsWith('globalThis.__lgDefault = object;'));
    },
  );
  test('named export functions and default export aliases', () {
    expect(
      prepareSingleFileJs('export function __jsEvalReturn(){return {}}'),
      ' function __jsEvalReturn(){return {}}',
    );
    expect(
      prepareSingleFileJs('const spider={};export {spider as default};'),
      'const spider={};globalThis.__lgDefault = spider;;',
    );
  });
  test('actual imports and re-exports require bundling', () {
    for (final input in [
      "import x from './x.js';",
      "export {x} from './x.js';",
      "export * from './x.js';",
    ]) {
      expect(() => prepareSingleFileJs(input), throwsFormatException);
    }
  });
  test('commented import is permitted and classic rules are unchanged', () {
    const source = '/* import x from "x" */\nvar rule={title:"test"};';
    expect(prepareSingleFileJs(source), source);
  });
}
