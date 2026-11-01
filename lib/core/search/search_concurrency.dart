/// Limits asynchronous source I/O; this does not create Dart worker threads.
abstract final class SearchConcurrency {
  static const settingKey = 'searchConcurrency';
  static const defaultLimit = 16;
  static const options = [8, 16, 32];
  static const sourceTimeout = Duration(seconds: 30);

  static int fromSetting(Object? value) {
    final parsed = value is int ? value : int.tryParse('$value');
    return options.contains(parsed) ? parsed! : defaultLimit;
  }
}
