import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/models/models.dart';
import 'package:tvbox/ui/components.dart';

void main() {
  test('relative and protocol-relative images and safe suffix headers', () {
    final headers = imageHeaders(
      null,
      Site({
        'api': 'http://example.org/api/list',
        'header': {'cookie': 'secret', 'user-agent': 'site'},
      }),
    );
    expect(headers.containsKey('cookie'), false);
    final req = posterRequest(
      '../poster.jpg@Referer=https://example.org/base/@User-Agent=poster',
      headers,
    );
    expect(req.url, 'https://example.org/poster.jpg');
    expect(req.headers['Referer'], 'https://example.org/base/');
    expect(req.headers['User-Agent'], 'poster');
    expect(
      posterRequest('//images.example.org/a.jpg', headers).url,
      'http://images.example.org/a.jpg',
    );
    expect(
      posterRequest('http://example.org/a@2x.jpg', headers).url,
      'http://example.org/a@2x.jpg',
    );
    expect(posterRequest('file:///private', headers).url, isEmpty);
  });
  test('generic httpHeaders merge safely by scope and case', () {
    final config = TvConfig(
      url: '',
      name: '',
      raw: {
        'httpHeaders': {
          'USER-AGENT': 'config-ua',
          'Referer': 'https://config.example/',
          'ORIGIN': 'https://config.example',
          'Cookie': 'config-secret',
          'Authorization': 'config-token',
        },
      },
    );
    final site = Site({
      'httpHeaders':
          '{"user-agent":"site-ua","rEfErEr":"https://site.example/",'
          '"cookie":"site-secret","AUTHORIZATION":"site-token"}',
    });
    final headers = imageHeaders(config, site);
    expect(headers, {
      'user-agent': 'site-ua',
      'rEfErEr': 'https://site.example/',
      'ORIGIN': 'https://config.example',
    });
  });

  test('generic aliases and explicit image headers override without case duplicates', () {
    final config = TvConfig(
      url: '',
      name: '',
      raw: {
        'httpHeaders': {'User-Agent': 'config', 'origin': 'config-origin'},
        'headers': {'USER-agent': 'config-alias'},
        'imageHeaders': {'REFERER': 'config-image', 'Cookie': 'image-cookie'},
      },
    );
    final site = Site({
      'httpHeaders': {
        'user-agent': 'site',
        'Origin': 'site-origin',
        'Cookie': 'secret',
      },
      'header': {'USER-AGENT': 'site-alias'},
      'imageHeaders': {
        'referer': 'site-image',
        'ORIGIN': 'image-origin',
        'Authorization': 'image-token',
      },
    });
    final headers = imageHeaders(config, site);
    expect(headers, {
      'USER-AGENT': 'site-alias',
      'referer': 'site-image',
      'ORIGIN': 'image-origin',
      'Cookie': 'image-cookie',
      'Authorization': 'image-token',
    });
  });
}
