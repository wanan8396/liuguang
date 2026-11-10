/// A paste can contain multiple independent subscriptions, one URL per line.
List<String> subscriptionUrls(String text) {
  final urls = <String>{};
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final value = line.trim();
    if (value.isEmpty) continue;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        RegExp(r'\s').hasMatch(value)) {
      throw FormatException(
        '第 ${urls.length + 1} 个地址无效，请每行填写一个 HTTP / HTTPS 链接',
      );
    }
    urls.add(uri.toString());
  }
  if (urls.isEmpty) throw const FormatException('请填写至少一个订阅地址');
  return urls.toList();
}

class SubscriptionImportItem {
  const SubscriptionImportItem(
    this.url, {
    this.status = 'queued',
    this.repositories = 0,
    this.error,
  });
  final String url;
  final String status;
  final int repositories;
  final String? error;
}
