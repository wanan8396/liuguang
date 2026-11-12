import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../core/engine/android_engine_bridge.dart';
import '../../ui/components.dart';

/// The Android service deliberately belongs to this page, not the controller:
/// leaving this page (or putting the application in background) stops it.
class EngineBridgePage extends StatefulWidget {
  const EngineBridgePage({super.key, required this.controller});
  final AppController controller;

  @override
  State<EngineBridgePage> createState() => _EngineBridgePageState();
}

class _EngineBridgePageState extends State<EngineBridgePage>
    with WidgetsBindingObserver {
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  late final AndroidEngineBridgeService _service;
  bool _working = false;
  bool _showToken = false;
  String? _testResult;
  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service = AndroidEngineBridgeService()..addListener(_serviceChanged);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final secret = await c.store.readSecret(
        AndroidEngineBridgeApi.connectionSecretKey,
      );
      if (!mounted || secret == null || secret.isEmpty) return;
      final decoded = jsonDecode(secret);
      if (decoded is Map) {
        _endpoint.text = decoded['endpoint'] is String
            ? decoded['endpoint'] as String
            : '';
        _token.text = decoded['token'] is String
            ? decoded['token'] as String
            : '';
      }
    } catch (_) {
      if (mounted) setState(() => _testResult = '读取加密连接配置失败，请重新填写');
    }
  }

  void _serviceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_service.stop());
    }
  }

  Future<void> _task(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    await runUi(context, action);
    if (mounted) setState(() => _working = false);
  }

  Future<void> _test() => _task(() async {
    final bridge = AndroidEngineBridgeApi(
      endpoint: _endpoint.text,
      token: _token.text,
    );
    try {
      final result = jsonDecode(await bridge.capabilities());
      if (result is! Map) throw const FormatException('Android 引擎能力结果格式错误');
      if (mounted) {
        setState(
          () => _testResult =
              '连接成功 · Android 原生引擎 · JAR ${result['jar'] == true ? '可用' : '未声明'} · JS ${result['js'] == true ? '可用' : '未声明'}',
        );
      }
    } finally {
      await bridge.dispose();
    }
  });

  Future<void> _save() => _task(() async {
    final endpoint = AndroidEngineBridgeApi.validateEndpoint(_endpoint.text);
    // Controller owns encrypted persistence and engine switching. Neither the
    // bearer nor its connection envelope is put into ordinary store settings.
    await c.configureAndroidBridge(endpoint, _token.text.trim());
    if (mounted) {
      setState(() => _testResult = '连接已保存到本机加密凭据存储');
      showMessage(context, 'Android 引擎连接已保存');
    }
  });

  Future<void> _clear() => _task(() async {
    await c.clearAndroidBridge();
    _endpoint.clear();
    _token.clear();
    if (mounted) setState(() => _testResult = '已清除 Android 引擎连接');
  });

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showMessage(context, message);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_serviceChanged);
    _service.dispose();
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Android 原生引擎桥接')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_working) const LinearProgressIndicator(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.hub_outlined,
                  size: 36,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '由 Android 执行 DEX / JAR',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Windows / iOS 通过同一局域网调用 Android 已有 CatVod 引擎。DEX / JAR 始终在 Android 设备执行，不在电脑或 iPhone 本地执行。\n\n两台设备请连接同一可信 Wi-Fi。Android 保持前台停留在本页，离开页面或进入后台即停止；10 分钟无请求自动停止。HTTP 局域网传输为明文，请勿将地址或令牌发给其他人。',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (Platform.isAndroid)
          _androidCard(context)
        else
          _connectionCard(context),
      ],
    ),
  );

  Widget _androidCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本机局域网引擎服务', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(_service.running ? '服务运行中 · 请保持本页前台' : '默认关闭；每次开启生成新令牌'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _working
                ? null
                : () => _task(
                    _service.running ? _service.stop : () => _service.start(),
                  ),
            icon: Icon(
              _service.running ? Icons.stop_circle_outlined : Icons.wifi,
            ),
            label: Text(_service.running ? '停止引擎服务并关闭所有会话' : '显式开启引擎服务'),
          ),
          if (_service.running) ...[
            const SizedBox(height: 20),
            for (final address in _service.addresses)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('引擎地址'),
                subtitle: SelectableText(address),
                trailing: IconButton(
                  tooltip: '复制引擎地址',
                  icon: const Icon(Icons.copy),
                  onPressed: () => _task(() => _copy(address, '地址已复制')),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '临时令牌（Secret，不包含在备份中）',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SelectableText(_service.token ?? ''),
            TextButton.icon(
              onPressed: () =>
                  _task(() => _copy(_service.token ?? '', '令牌已复制，请只粘贴到自己的设备')),
              icon: const Icon(Icons.copy),
              label: const Text('复制完整令牌'),
            ),
            const Text(
              '停止服务后全部媒体 capability 和会话立即失效。若地址为 127.0.0.1，请先连接 Wi-Fi 后重新开启。',
            ),
          ],
        ],
      ),
    ),
  );

  Widget _connectionCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('连接 Android 引擎', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _endpoint,
            enabled: !_working,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'HTTP(S) 引擎地址',
              hintText: 'http://192.168.1.23:45678',
              helperText: '仅私有局域网 / loopback IPv4，地址中不含令牌',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            enabled: !_working,
            obscureText: !_showToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Android 显示的完整令牌',
              helperText: '保存到本机加密凭据存储，不进入应用备份',
              suffixIcon: IconButton(
                tooltip: _showToken ? '隐藏令牌' : '显示令牌',
                onPressed: () => setState(() => _showToken = !_showToken),
                icon: Icon(
                  _showToken ? Icons.visibility_off : Icons.visibility,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: _working ? null : _test,
                icon: const Icon(Icons.network_check),
                label: const Text('测试连接'),
              ),
              FilledButton.icon(
                onPressed: _working ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存并使用'),
              ),
              TextButton(
                onPressed: _working ? null : _clear,
                child: const Text('清除连接'),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 16),
            Text(_testResult!),
          ],
        ],
      ),
    ),
  );
}
