import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/models/models.dart';

void main() {
  test(
    'local media omits Origin without changing upstream or subtitle headers',
    () {
      for (final host in ['127.0.0.1', 'localhost', '[::1]']) {
        final playback = Playback(
          url: 'http://$host:1234/stream/key?token=fixture',
          subtitle: 'https://media.invalid/subtitle.vtt',
          headers: const {
            'Origin': 'https://site.invalid',
            'oRiGiN': 'https://alternate.invalid',
            'Referer': 'https://site.invalid/watch',
            'Cookie': 'session=fixture',
          },
        );
        expect(playback.mediaHeaders, {
          'Referer': 'https://site.invalid/watch',
          'Cookie': 'session=fixture',
        });
        expect(playback.headers['Origin'], 'https://site.invalid');
        expect(playback.headers['oRiGiN'], 'https://alternate.invalid');
        expect(playback.headers['Cookie'], 'session=fixture');
      }
    },
  );

  test(
    'direct media retains Origin, including names that resemble loopback',
    () {
      for (final url in [
        'https://cdn.invalid/film.m3u8',
        'https://localhost.cdn.invalid/film.m3u8',
        'https://127.0.0.1.cdn.invalid/film.m3u8',
      ]) {
        final playback = Playback(
          url: url,
          headers: const {'Origin': 'https://site.invalid'},
        );
        expect(playback.mediaHeaders, playback.headers);
      }
    },
  );
}
