Duration? playbackStartPosition({
  required bool live,
  required Duration requested,
}) => live || requested <= Duration.zero ? null : requested;

/// mpv emits these seek advisories through the same stream as playback errors.
/// Match complete lines so a real error alongside an advisory is still shown.
bool isNonFatalSeekMessage(String message) {
  const advisories = {
    'Cannot seek in this stream',
    "You can force it with '--force-seekable=yes'",
  };
  final lines = message.trim().split(RegExp(r'[\r\n]+'));
  return lines.every(
    (line) => advisories.contains(line.trim().replaceFirst(RegExp(r'\.$'), '')),
  );
}

class PlaybackErrorState {
  String? error;
  bool _fromPlayer = false;
  Duration? _lastPosition, _recoveryStart;

  void clear() {
    error = null;
    _fromPlayer = false;
    _lastPosition = null;
    _recoveryStart = null;
  }

  void reportOpenError(Object failure) {
    clear();
    error = failure.toString();
  }

  bool reportPlayerError(String message, {required Duration position}) {
    if (isNonFatalSeekMessage(message)) return false;
    // A late engine event must not replace a resolver/open failure.
    if (error != null && !_fromPlayer) return false;
    error = message;
    _fromPlayer = true;
    _lastPosition = position;
    _recoveryStart = null;
    return true;
  }

  void observePosition(
    Duration position, {
    required bool playing,
    required bool buffering,
  }) {
    if (!_fromPlayer || error == null) return;
    final previous = _lastPosition;
    _lastPosition = position;
    if (!playing || buffering || previous == null || position <= previous) {
      _recoveryStart = null;
      return;
    }
    _recoveryStart ??= position;
    // Playing=true can precede a failed open. Require an advancing playback
    // clock before removing an error after a decoder/network recovery.
    if (position - _recoveryStart! >= const Duration(seconds: 1)) clear();
  }
}
