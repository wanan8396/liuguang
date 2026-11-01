import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';
import 'library_page.dart';
import 'pairing_page.dart';
import 'source_management_page.dart';
import 'subscriptions_page.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.controller});
  final AppController controller;
  void _push(BuildContext context, Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('我的流光')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 40,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '流光',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '每一段光影，值得珍藏',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _libraryCard(
                  context,
                  Icons.favorite_outline,
                  '我的收藏',
                  '${controller.store.favorites.length} 部',
                  () => _push(context, LibraryPage(controller: controller)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _libraryCard(
                  context,
                  Icons.history,
                  '观看历史',
                  '${controller.store.history.length} 条',
                  () => _push(
                    context,
                    LibraryPage(controller: controller, history: true),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text('内容与连接', style: Theme.of(context).textTheme.titleSmall),
          ),
          Card(
            child: Column(
              children: [
                _tile(
                  context,
                  Icons.rss_feed,
                  '视频订阅',
                  '${controller.subscriptions.length} 个入口 · ${controller.configs.length} 个仓库',
                  () =>
                      _push(context, SubscriptionsPage(controller: controller)),
                ),
                const Divider(indent: 56, height: 1),
                _tile(
                  context,
                  Icons.live_tv,
                  '直播订阅',
                  'M3U / TXT / JSON',
                  () => _push(
                    context,
                    SubscriptionsPage(controller: controller, live: true),
                  ),
                ),
                const Divider(indent: 56, height: 1),
                _tile(
                  context,
                  Icons.tune,
                  '源管理与凭据',
                  '站点启停、排序与 Cookie / Token',
                  () => _push(
                    context,
                    SourceManagementPage(controller: controller),
                  ),
                ),
                const Divider(indent: 56, height: 1),
                _tile(
                  context,
                  Icons.devices,
                  '数据推送',
                  '临时局域网配对 · 本机确认',
                  () => _push(context, PairingPage(controller: controller)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: Column(
              children: [
                _tile(
                  context,
                  Icons.settings_outlined,
                  '设置',
                  '主题、缓存与插件信任',
                  () => _push(context, SettingsPage(controller: controller)),
                ),
                const Divider(indent: 56, height: 1),
                _tile(
                  context,
                  Icons.info_outline,
                  '关于流光',
                  '版本与开源许可',
                  () => runUi(context, () async {
                    final info = await PackageInfo.fromPlatform();
                    if (context.mounted) {
                      showAboutDialog(
                        context: context,
                        applicationName: '流光',
                        applicationVersion:
                            '${info.version} (${info.buildNumber})',
                        applicationLegalese: '流光不内置视频内容。仅播放用户自行提供的合法订阅与媒体。',
                        applicationIcon: Icon(
                          Icons.play_circle_fill,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        children: [
                          const Text(
                            'Flutter · media_kit\n点击「查看许可」阅读本应用依赖的开源许可证。',
                          ),
                        ],
                      );
                    }
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          Text(
            '光影随行，自由探索',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
  Widget _tile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    trailing: const Icon(Icons.chevron_right, size: 19),
    onTap: onTap,
  );
  Widget _libraryCard(
    BuildContext context,
    IconData icon,
    String title,
    String count,
    VoidCallback onTap,
  ) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(count, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _working = false;
  AppController get c => widget.controller;
  Future<void> _task(Future<void> Function() task) async {
    if (_working) return;
    setState(() => _working = true);
    await runUi(context, task);
    if (mounted) setState(() => _working = false);
  }

  Future<void> _export() => _task(() async {
    final text = await c.store.exportBackup();
    final bytes = Uint8List.fromList(utf8.encode(text));
    final name =
        'liuguang-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';
    final file = XFile.fromData(
      bytes,
      mimeType: 'application/json',
      name: name,
    );
    // Android/iOS file_selector exposes import, but not a save dialog. Their
    // share sheet is the native document-export flow; desktop uses save-as.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [file],
          fileNameOverrides: [name],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      final destination = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'JSON 备份',
            extensions: ['json'],
            mimeTypes: ['application/json'],
            uniformTypeIdentifiers: ['public.json'],
          ),
        ],
      );
      if (destination != null) {
        await file.saveTo(destination.path);
        if (mounted) showMessage(context, '备份已保存');
      }
    }
  });
  Future<void> _restore() => _task(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '流光备份',
          extensions: ['json'],
          mimeTypes: ['application/json'],
          uniformTypeIdentifiers: ['public.json'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    if (!await confirm(
      context,
      '恢复备份？',
      '将从 ${file.name} 恢复订阅、收藏、历史和偏好。源凭据不包含在备份中，请单独填写。',
    )) {
      return;
    }
    await c.store.restoreBackup(await file.readAsString());
    await c.reloadAfterRestore();
    if (mounted) showMessage(context, '备份已恢复');
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_working) const LinearProgressIndicator(),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('外观', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 14),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                      ),
                      ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                    ],
                    selected: {c.themeMode},
                    onSelectionChanged: (value) =>
                        _task(() => c.setThemeMode(value.first)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清理缓存'),
                  subtitle: const Text('清理数据缓存与内存图片，保留个人数据'),
                  enabled: !_working,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _task(() async {
                    final bytes = await c.store.clearCache();
                    PaintingBinding.instance.imageCache.clear();
                    PaintingBinding.instance.imageCache.clearLiveImages();
                    if (context.mounted) {
                      showMessage(
                        context,
                        '已清理 ${(bytes / 1024 / 1024).toStringAsFixed(2)} MB 缓存',
                      );
                    }
                  }),
                ),
                SwitchListTile(
                  title: const Text('信任当前仓库插件'),
                  subtitle: Text(c.currentConfig?.name ?? '尚未选择仓库'),
                  value: c.pluginsTrusted,
                  onChanged: c.currentConfig == null || _working
                      ? null
                      : (trusted) async {
                          if (!trusted ||
                              await confirm(
                                context,
                                '信任此仓库？',
                                '只有可信的订阅才应获得执行 JAR / JS 插件的权限。',
                              )) {
                            await _task(() => c.trustPlugins(trusted));
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('导出备份'),
                  subtitle: const Text('不包含源凭据和临时配对信息'),
                  onTap: _working ? null : _export,
                  trailing: const Icon(Icons.chevron_right),
                ),
                ListTile(
                  leading: const Icon(Icons.restore_page_outlined),
                  title: const Text('从文件恢复'),
                  subtitle: const Text('选择流光 JSON 备份文件'),
                  onTap: _working ? null : _restore,
                  trailing: const Icon(Icons.chevron_right),
                ),
                ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('撤销上次恢复'),
                  subtitle: const Text('恢复到上次导入备份之前的状态'),
                  onTap: _working
                      ? null
                      : () => _task(() async {
                          final snapshot = await c.store
                              .readLastRestoreBackup();
                          if (!mounted) return;
                          if (snapshot == null) {
                            showMessage(this.context, '没有可撤销的恢复记录');
                            return;
                          }
                          if (!await confirm(
                            this.context,
                            '撤销上次恢复？',
                            '将用恢复前快照替换当前订阅、收藏、历史与设置。',
                          )) {
                            return;
                          }
                          await c.store.restoreLastRestoreBackup();
                          await c.reloadAfterRestore();
                          if (mounted) {
                            showMessage(this.context, '已恢复到备份导入前的状态');
                          }
                        }),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
