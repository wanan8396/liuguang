import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/discovery/line_scanner.dart';
import 'package:tvbox/features/discovery/line_discovery_page.dart';

void main() {
  test('all discovered nodes remain visible including failed and pending', () {
    final root = ScanNode(url: 'https://example.org')
      ..kind = 'multi_urls'
      ..status = 'ok';
    root.children.addAll(
      List.generate(
        150,
        (i) =>
            ScanNode(url: 'https://example.org/$i')
              ..status = i.isEven ? 'fail' : 'pending',
      ),
    );
    final results = discoveryResults([root]);
    expect(results.length, 151);
    expect(results.last.url, endsWith('/149'));
    expect(results.where((n) => n.status == 'fail').length, 75);
  });
}
