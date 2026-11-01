/// Limits asynchronous source I/O; this does not create Dart worker threads.
abstract final class SearchConcurrency {
  static const defaultLimit = 16;
  static const sourceTimeout = Duration(seconds: 30);
}
