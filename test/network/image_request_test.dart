import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/core/network/image_request.dart';

void main() {
  test('嗷呜封面附带的 User-Agent 从路径分离并覆盖默认值', () {
    const agent = 'Dalvik/2.1.0 (Linux; U; Android 16; PLQ110)';
    final request = ImageRequest.parse(
      'https://image.test/poster.jpg@User-Agent=$agent',
      headers: {'user-agent': 'default', 'Referer': 'https://site.test/'},
    );
    expect(request.url, 'https://image.test/poster.jpg');
    expect(request.headers, {
      'User-Agent': agent,
      'Referer': 'https://site.test/',
    });
  });

  test('荐片 Headers JSON、编码 JSON 和管道请求头均可读取', () {
    for (final suffix in [
      '@Headers={"User-Agent":"jianpian-android/360","Referer":"https://site.test/"}',
      '@Headers=${Uri.encodeComponent('{"User-Agent":"jianpian-android/360","Referer":"https://site.test/"}')}',
      '|User-Agent=jianpian-android%2F360&Referer=https%3A%2F%2Fsite.test%2F',
      '@User-Agent=jianpian-android/360@Referer=https://site.test/',
    ]) {
      final request = ImageRequest.parse('https://image.test/a.jpg$suffix');
      expect(request.url, 'https://image.test/a.jpg');
      expect(request.headers, {
        'User-Agent': 'jianpian-android/360',
        'Referer': 'https://site.test/',
      });
    }
  });

  test('不误删普通 @ 路径、CDN 缩放参数和签名查询', () {
    for (final url in [
      'https://image.test/a@2x.jpg',
      'https://image.test/a.jpg@320w_480h',
      'https://image.test/a.jpg?signature=a%2Bb%3D&size=2',
      'https://user@image.test/a.jpg',
    ]) {
      expect(ImageRequest.parse(url).url, url);
    }
    expect(
      ImageRequest.parse('//image.test/a.jpg').url,
      'https://image.test/a.jpg',
    );
  });

  test('损坏的附加 JSON 保留正确图片地址，非法请求头不发送', () {
    final malformed = ImageRequest.parse(
      'https://image.test/a.jpg@Headers={bad',
      headers: {'User-Agent': 'default'},
    );
    expect(malformed.url, 'https://image.test/a.jpg');
    expect(malformed.headers, {'User-Agent': 'default'});
    final invalid = ImageRequest.parse(
      'https://image.test/a.jpg@Headers={"Referer":"one\\r\\ntwo","bad key":"value"}',
    );
    expect(invalid.headers, isEmpty);
  });
}
