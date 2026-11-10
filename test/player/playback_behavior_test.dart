import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/features/player/playback_behavior.dart';

void main() {
  test('直播即使带有历史进度也不设置起播位置', () {
    for (final requested in [Duration.zero, const Duration(minutes: 5)]) {
      expect(playbackStartPosition(live: true, requested: requested), isNull);
    }
  });

  test('点播从零打开不触发 seek，正数历史进度仍可续播', () {
    expect(
      playbackStartPosition(live: false, requested: Duration.zero),
      isNull,
    );
    expect(
      playbackStartPosition(
        live: false,
        requested: const Duration(seconds: -1),
      ),
      isNull,
    );
    expect(
      playbackStartPosition(live: false, requested: const Duration(minutes: 5)),
      const Duration(minutes: 5),
    );
  });

  test('不支持 seek 的提示不遮挡播放画面', () {
    final state = PlaybackErrorState();
    for (final message in [
      'Cannot seek in this stream.',
      "You can force it with '--force-seekable=yes'.",
      "You can force it with '--force-seekable=yes'",
      "Cannot seek in this stream.\nYou can force it with '--force-seekable=yes'.\n",
    ]) {
      expect(
        state.reportPlayerError(message, position: Duration.zero),
        isFalse,
      );
      expect(state.error, isNull);
    }
  });

  test('HTTP、解码失败及与提示混合的错误不会被过滤', () {
    for (final message in [
      'HTTP error 403 Forbidden',
      'Failed to initialize a video decoder',
      'tcp: Connection refused',
      "Failed to open media.\nYou can force it with '--force-seekable=yes'.",
    ]) {
      final state = PlaybackErrorState();
      expect(state.reportPlayerError(message, position: Duration.zero), isTrue);
      expect(state.error, message);
      state.reportPlayerError(
        "You can force it with '--force-seekable=yes'.",
        position: Duration.zero,
      );
      expect(state.error, message);
    }
  });

  test('playing 状态或缓冲中的时钟不会清除真实错误', () {
    final state = PlaybackErrorState()
      ..reportPlayerError('tcp: Connection refused', position: Duration.zero);
    state.observePosition(Duration.zero, playing: true, buffering: false);
    state.observePosition(
      const Duration(seconds: 2),
      playing: true,
      buffering: true,
    );
    state.observePosition(
      const Duration(seconds: 4),
      playing: false,
      buffering: false,
    );
    expect(state.error, 'tcp: Connection refused');
  });

  test('播放连续恢复一秒后清除旧引擎错误，暂停与停滞重置恢复计时', () {
    final state = PlaybackErrorState()
      ..reportPlayerError('decoder retry', position: Duration.zero);
    void position(int milliseconds, {bool playing = true}) =>
        state.observePosition(
          Duration(milliseconds: milliseconds),
          playing: playing,
          buffering: false,
        );
    position(100);
    position(500);
    expect(state.error, isNotNull);
    position(500, playing: false);
    position(700);
    position(1200);
    expect(state.error, isNotNull);
    position(1200);
    position(1400);
    position(2000);
    expect(state.error, isNotNull);
    position(2400);
    expect(state.error, isNull);
  });

  test('解析或打开失败不会被旧播放事件和晚到日志覆盖', () {
    final state = PlaybackErrorState()..reportOpenError('解析地址失败');
    state.reportPlayerError('late engine log', position: Duration.zero);
    for (var seconds = 1; seconds <= 3; seconds++) {
      state.observePosition(
        Duration(seconds: seconds),
        playing: true,
        buffering: false,
      );
    }
    expect(state.error, '解析地址失败');
    state.clear();
    expect(state.error, isNull);
  });
}
