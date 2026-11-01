import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../../core/models/models.dart';
import '../../ui/components.dart';

typedef PlaybackResolver =
    Future<Playback> Function(PlayLine line, Episode episode);
typedef ProgressWriter =
    Future<void> Function(
      PlayLine line,
      Episode episode,
      Duration position,
      Duration duration,
    );

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.title,
    required this.lines,
    required this.resolve,
    this.initialLine = 0,
    this.initialEpisode = 0,
    this.initialPosition = Duration.zero,
    this.onProgress,
    this.live = false,
  });
  final String title;
  final List<PlayLine> lines;
  final int initialLine, initialEpisode;
  final Duration initialPosition;
  final PlaybackResolver resolve;
  final ProgressWriter? onProgress;
  final bool live;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _video;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  int _line = 0, _episode = 0, _generation = 0;
  bool _loading = true, _fullscreen = false, _portrait = false, _locked = false;
  bool _controls = true, _closing = false, _closed = false;
  double _rate = 1, _volume = .5, _brightness = .5;
  double? _aspect;
  String? _error, _hint;
  Duration _position = Duration.zero, _duration = Duration.zero;
  Duration? _dragPosition;
  Timer? _saveTimer, _hideTimer;
  Future<void>? _closeFuture;
  PlayLine get _currentLine => widget.lines[_line];
  Episode get _currentEpisode => _currentLine.episodes[_episode];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player();
    _video = VideoController(_player);
    _line = widget.initialLine;
    _episode = widget.initialEpisode;
    _subscriptions.add(
      _player.stream.position.listen((value) {
        if (mounted && !_closing) setState(() => _position = value);
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((value) {
        if (mounted && !_closing) setState(() => _duration = value);
      }),
    );
    _subscriptions.add(
      _player.stream.playing.listen((_) {
        if (mounted && !_closing) setState(() {});
      }),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((_) {
        if (mounted && !_closing) setState(() {});
      }),
    );
    _subscriptions.add(
      _player.stream.tracks.listen((_) {
        if (mounted && !_closing) setState(() {});
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (mounted && !_closing) setState(() => _error = error);
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !widget.live &&
            _episode + 1 < _currentLine.episodes.length) {
          _open(_line, _episode + 1);
        }
      }),
    );
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _persist());
    _initializeDevice();
    _open(_line, _episode, start: widget.initialPosition, initial: true);
  }

  Future<void> _initializeDevice() async {
    try {
      _volume = await VolumeController.instance.getVolume();
      _brightness = await ScreenBrightness.instance.application;
    } catch (error) {
      if (mounted) setState(() => _hint = '设备手势控制暂不可用：$error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !_closing && !_closed) {
      unawaited(_player.pause());
      unawaited(_persist());
    }
  }

  Future<void> _persist() async {
    if (widget.onProgress == null ||
        _duration <= Duration.zero ||
        _loading ||
        _closed) {
      return;
    }
    try {
      await widget.onProgress!(
        _currentLine,
        _currentEpisode,
        _position,
        _duration,
      );
    } catch (error) {
      if (mounted && !_closing) setState(() => _hint = '进度保存失败：$error');
    }
  }

  Future<void> _open(
    int line,
    int episode, {
    Duration start = Duration.zero,
    bool initial = false,
  }) async {
    if (_closing || _closed) return;
    if (!initial) await _persist();
    if (!mounted || _closing || _closed) return;
    final generation = ++_generation;
    setState(() {
      _line = line;
      _episode = episode;
      _loading = true;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      await _player.stop();
      final playback = await widget.resolve(_currentLine, _currentEpisode);
      if (!mounted || generation != _generation || _closing) return;
      if (playback.parse) throw StateError('此线路仍需要网页解析，尚未获得可播放地址，请切换线路。');
      final uri = Uri.tryParse(playback.url);
      if (uri == null ||
          ![
            'http',
            'https',
            'file',
            'rtsp',
            'rtmp',
            'udp',
            'rtp',
            'srt',
          ].contains(uri.scheme)) {
        throw StateError('播放地址无效或协议不受支持：${playback.url}');
      }
      await _player.open(
        Media(playback.url, httpHeaders: playback.headers, start: start),
      );
      await _player.setRate(_rate);
      if (playback.subtitle?.isNotEmpty ?? false) {
        try {
          final response = await _dio.get<String>(
            playback.subtitle!,
            options: Options(
              responseType: ResponseType.plain,
              headers: playback.headers,
            ),
          );
          if (mounted && generation == _generation && !_closing) {
            await _player.setSubtitleTrack(
              SubtitleTrack.data(response.data ?? '', title: '源字幕'),
            );
          }
        } catch (error) {
          if (mounted && generation == _generation && !_closing) {
            setState(() => _hint = '字幕加载失败，视频仍可继续播放：$error');
          }
        }
      }
    } catch (error) {
      if (mounted && generation == _generation && !_closing) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation && !_closing) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _fullscreenTo(bool enabled) async {
    setState(() {
      _fullscreen = enabled;
      _controls = true;
      _locked = false;
    });
    await SystemChrome.setEnabledSystemUIMode(
      enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    await SystemChrome.setPreferredOrientations(
      enabled
          ? (_portrait
                ? [DeviceOrientation.portraitUp]
                : [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ])
          : [DeviceOrientation.portraitUp],
    );
  }

  Future<void> _close() => _closeFuture ??= _release();

  Future<void> _release() async {
    if (_closed) return;
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _generation++;
    await _persist();
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _dio.close(force: true);
    await _player.dispose();
    try {
      await ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (_) {
      /* Platform may not expose application brightness. */
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  Future<void> _leave() async {
    if (_fullscreen) {
      await _fullscreenTo(false);
      return;
    }
    if (_closing) return;
    setState(() => _closing = true);
    await _close();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close());
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    _hideTimer?.cancel();
    if (_controls && _player.state.playing) {
      _hideTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  Future<void> _tracks() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('音轨与字幕', style: Theme.of(context).textTheme.titleLarge),
              const ListTile(title: Text('音频轨道')),
              for (final track in _player.state.tracks.audio)
                ListTile(
                  title: Text(
                    track.title ??
                        track.language ??
                        (track.id == 'auto'
                            ? '自动'
                            : track.id == 'no'
                            ? '关闭音频'
                            : '音轨 ${track.id}'),
                  ),
                  leading: Icon(
                    _player.state.track.audio == track
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    runUi(this.context, () => _player.setAudioTrack(track));
                  },
                ),
              const ListTile(title: Text('字幕轨道')),
              for (final track in _player.state.tracks.subtitle)
                ListTile(
                  title: Text(
                    track.title ??
                        track.language ??
                        (track.id == 'auto'
                            ? '自动'
                            : track.id == 'no'
                            ? '关闭字幕'
                            : '字幕 ${track.id}'),
                  ),
                  leading: Icon(
                    _player.state.track.subtitle == track
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    runUi(this.context, () => _player.setSubtitleTrack(track));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('加载本地字幕'),
                onTap: () {
                  Navigator.pop(context);
                  runUi(this.context, () async {
                    final file = await openFile(
                      acceptedTypeGroups: [
                        const XTypeGroup(
                          label: '字幕',
                          extensions: ['srt', 'vtt', 'ass', 'ssa'],
                          mimeTypes: [
                            'text/plain',
                            'text/vtt',
                            'application/x-subrip',
                          ],
                          uniformTypeIdentifiers: ['public.text'],
                        ),
                      ],
                    );
                    if (file != null) {
                      await _player.setSubtitleTrack(
                        SubtitleTrack.data(
                          await file.readAsString(),
                          title: file.name,
                        ),
                      );
                    }
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, VoidCallback? action) =>
      IconButton(
        tooltip: tooltip,
        onPressed: action,
        color: Colors.white,
        icon: Icon(icon),
        style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      );
  Widget _videoArea() => LayoutBuilder(
    builder: (context, size) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      onDoubleTap: _locked ? null : () => _player.playOrPause(),
      onHorizontalDragStart: _locked || widget.live
          ? null
          : (_) => _dragPosition = _position,
      onHorizontalDragUpdate: _locked || widget.live
          ? null
          : (event) {
              final max = _duration.inMilliseconds;
              final target =
                  (_dragPosition ?? _position).inMilliseconds +
                  (event.delta.dx / size.maxWidth * 120000).round();
              setState(() {
                _dragPosition = Duration(milliseconds: target.clamp(0, max));
                _hint = '快进至 ${timeLabel(_dragPosition!)}';
              });
            },
      onHorizontalDragEnd: _locked || widget.live
          ? null
          : (_) {
              if (_dragPosition != null) _player.seek(_dragPosition!);
              _dragPosition = null;
            },
      onVerticalDragUpdate: _locked
          ? null
          : (event) => runUi(context, () async {
              final delta = -event.delta.dy / size.maxHeight;
              if (event.localPosition.dx < size.maxWidth / 2) {
                _brightness = (_brightness + delta).clamp(0, 1);
                await ScreenBrightness.instance.setApplicationScreenBrightness(
                  _brightness,
                );
                if (mounted) {
                  setState(() => _hint = '亮度 ${(_brightness * 100).round()}%');
                }
              } else {
                _volume = (_volume + delta).clamp(0, 1);
                await VolumeController.instance.setVolume(_volume);
                if (mounted) {
                  setState(() => _hint = '音量 ${(_volume * 100).round()}%');
                }
              }
            }),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: Video(
              controller: _video,
              controls: NoVideoControls,
              aspectRatio: _aspect,
            ),
          ),
          if (_loading || _player.state.buffering)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (_error != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                color: Colors.black87,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 4,
                    ),
                    TextButton(
                      onPressed: () => _open(_line, _episode),
                      child: const Text('重试当前线路'),
                    ),
                  ],
                ),
              ),
            ),
          if (_controls) ...[
            if (_locked)
              Positioned(
                left: 8,
                top: 8,
                child: _button(
                  Icons.lock,
                  '解除锁定',
                  () => setState(() => _locked = false),
                ),
              )
            else ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black45,
                  child: Row(
                    children: [
                      _button(Icons.arrow_back, '返回', _leave),
                      Expanded(
                        child: Text(
                          _currentEpisode.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      _button(
                        Icons.lock_open,
                        '锁定屏幕',
                        () => setState(() => _locked = true),
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _button(
                      Icons.skip_previous,
                      '上一集',
                      _episode > 0 && !_loading
                          ? () => _open(_line, _episode - 1)
                          : null,
                    ),
                    _button(
                      _player.state.playing
                          ? Icons.pause_circle
                          : Icons.play_circle,
                      '播放或暂停',
                      () => _player.playOrPause(),
                    ),
                    _button(
                      Icons.skip_next,
                      '下一集',
                      _episode + 1 < _currentLine.episodes.length && !_loading
                          ? () => _open(_line, _episode + 1)
                          : null,
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.live)
                        Row(
                          children: [
                            const SizedBox(width: 8),
                            Text(
                              timeLabel(_position),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: _position.inMilliseconds
                                    .toDouble()
                                    .clamp(
                                      0,
                                      _duration.inMilliseconds.toDouble(),
                                    ),
                                max: _duration.inMilliseconds.toDouble().clamp(
                                  1,
                                  double.infinity,
                                ),
                                onChanged: (value) => _player.seek(
                                  Duration(milliseconds: value.round()),
                                ),
                              ),
                            ),
                            Text(
                              timeLabel(_duration),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ),
                      Row(
                        children: [
                          PopupMenuButton<double>(
                            tooltip: '播放速度',
                            initialValue: _rate,
                            onSelected: (value) => runUi(context, () async {
                              await _player.setRate(value);
                              setState(() => _rate = value);
                            }),
                            itemBuilder: (_) => [
                              for (final rate in [.5, .75, 1.0, 1.25, 1.5, 2.0])
                                PopupMenuItem(
                                  value: rate,
                                  child: Text('${rate}x'),
                                ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                '${_rate}x',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                          PopupMenuButton<double>(
                            tooltip: '画面比例',
                            onSelected: (value) => setState(
                              () => _aspect = value == 0 ? null : value,
                            ),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 0, child: Text('原始比例')),
                              PopupMenuItem(value: 16 / 9, child: Text('16:9')),
                              PopupMenuItem(value: 4 / 3, child: Text('4:3')),
                            ],
                            icon: const Icon(
                              Icons.aspect_ratio,
                              color: Colors.white,
                            ),
                          ),
                          _button(Icons.subtitles_outlined, '音轨与字幕', _tracks),
                          const Spacer(),
                          if (_fullscreen)
                            _button(Icons.screen_rotation, '切换横竖屏', () {
                              _portrait = !_portrait;
                              _fullscreenTo(true);
                            }),
                          _button(
                            _fullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            '全屏',
                            () => _fullscreenTo(!_fullscreen),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: Scaffold(
      backgroundColor: _fullscreen ? Colors.black : null,
      appBar: _fullscreen
          ? null
          : AppBar(
              title: Text(widget.title),
              leading: BackButton(onPressed: _leave),
            ),
      body: _fullscreen
          ? SafeArea(child: _videoArea())
          : Column(
              children: [
                AspectRatio(aspectRatio: 16 / 9, child: _videoArea()),
                if (_hint != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      _hint!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.live
                            ? '直播 · ${_currentLine.name}'
                            : '${_currentLine.name} · ${_currentEpisode.name}',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '左侧上下滑动调亮度，右侧调音量；横滑快进，双击暂停。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (var i = 0; i < widget.lines.length; i++)
                            ChoiceChip(
                              label: Text(widget.lines[i].name),
                              selected: _line == i,
                              onSelected: _loading ? null : (_) => _open(i, 0),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _currentLine.episodes.length; i++)
                            ChoiceChip(
                              label: Text(_currentLine.episodes[i].name),
                              selected: _episode == i,
                              onSelected: _loading
                                  ? null
                                  : (_) => _open(_line, i),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
}
