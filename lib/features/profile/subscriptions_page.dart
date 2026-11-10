import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';

class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({
    super.key,
    required this.controller,
    this.live = false,
  });
  final AppController controller;
  final bool live;
  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  final TextEditingController _url = TextEditingController();
  bool _working = false;
  AppController get c => widget.controller;
  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_working || c.importing || c.batchImporting) return;
    final value = _url.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        RegExp(r'\s').hasMatch(value)) {
      showMessage(context, '请填写一个 HTTP / HTTPS 订阅地址');
      return;
    }
    final urls = [uri.toString()];
    setState(() => _working = true);
    await runUi(context, () async {
      var added = 0;
      if (widget.live) {
        added = await c.addLiveSubscriptions(urls);
      } else {
        await c.importSubscriptions(urls, addOnly: true);
      }
      if (mounted) {
        final success =
            widget.live ||
            c.importQueue.isNotEmpty &&
                c.importQueue.every(
                  (item) => ['ready', 'existing'].contains(item.status),
                );
        if (success) {
          _url.clear();
        }
        showMessage(
          context,
          widget.live
              ? added > 0
                    ? '已追加，可继续输入下一个订阅'
                    : '此订阅已存在，已保留'
              : success
              ? c.importQueue.single.status == 'existing'
                    ? '此订阅已存在，已保留'
                    : '已追加，可继续输入下一个订阅'
              : '追加未完成，请查看下方诊断',
        );
      }
    });
    if (mounted) setState(() => _working = false);
  }

  Future<void> _rename(String url) async {
    final input = TextEditingController(text: c.subscriptionName(url));
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.edit_note_rounded),
        title: const Text('订阅名称'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '给订阅起个好记的名字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (name != null && mounted) {
      await runUi(context, () => c.renameSubscription(url, name));
    }
  }

  Future<void> _delete(String url) async {
    if (await confirm(
          context,
          '删除此订阅？',
          '${c.subscriptionName(url)}\n收藏和观看历史保留。',
        ) &&
        mounted) {
      await runUi(context, () => c.removeSubscription(url));
    }
  }

  Future<void> _clearOld() async {
    final urls = c.subscriptions
        .map((s) => s.url)
        .where((url) => url != defaultSubscription)
        .toList();
    if (urls.isEmpty) return;
    if (await confirm(
          context,
          '清理 ${urls.length} 个旧订阅？',
          '保留内置奇奇多仓，移除其他订阅。收藏和观看历史保留。',
        ) &&
        mounted) {
      await runUi(context, () => c.removeSubscriptions(urls));
    }
  }

  Future<void> _scan() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (value != null && mounted) {
      _url.text = value.trim();
    }
  }

  Future<void> _importFile() async => runUi(context, () async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '订阅配置',
          extensions: ['json', 'txt'],
          mimeTypes: ['application/json', 'text/plain'],
          uniformTypeIdentifiers: ['public.json', 'public.plain-text'],
        ),
      ],
    );
    if (file != null) {
      await c.importText(await file.readAsString(), name: file.name);
    }
  });
  Future<void> _share(String url) => runUi(context, () async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: url,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final waiting = _working || c.importing || c.batchImporting;
      final userSubscriptions = c.subscriptions
          .where((s) => s.url != defaultSubscription)
          .toList();
      final pageError = widget.live ? c.liveError : c.importError;
      final liveUrls = jsonList(
        c.store.setting('liveSubscriptions'),
      ).map(str).toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.live ? '直播订阅' : '订阅管理'),
          actions: [
            IconButton(
              tooltip: '扫码填写地址',
              onPressed: waiting ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
            ),
            if (!widget.live)
              IconButton(
                tooltip: '导入本地配置',
                onPressed: waiting ? null : _importFile,
                icon: const Icon(Icons.file_open_outlined),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.live ? '追加直播订阅' : '追加视频订阅',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '每次添加一个地址，已有订阅保留',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _url,
                      enabled: !waiting,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      maxLines: 1,
                      onSubmitted: waiting ? null : (_) => _add(),
                      autocorrect: false,
                      decoration: const InputDecoration(
                        hintText: '输入一个订阅地址 https://…',
                        prefixIcon: Icon(Icons.link),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: waiting ? null : _add,
                            icon: const Icon(Icons.add_link),
                            label: Text(waiting ? '追加中…' : '追加订阅'),
                          ),
                        ),
                        if (c.importing || c.batchImporting)
                          TextButton(
                            onPressed: c.cancelImport,
                            child: const Text('取消导入'),
                          ),
                      ],
                    ),
                    if (waiting)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
            if (pageError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ErrorNotice(error: pageError),
              ),
            if (!widget.live && c.importQueue.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导入结果 · ${c.importQueue.where((item) => !['queued', 'loading'].contains(item.status)).length}/${c.importQueue.length}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      for (final item in c.importQueue)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: item.status == 'loading'
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  ['ready', 'existing'].contains(item.status)
                                      ? Icons.check_circle_rounded
                                      : item.status == 'error' ||
                                            item.status == 'partial'
                                      ? Icons.error_outline_rounded
                                      : Icons.schedule_rounded,
                                  color: item.status == 'error'
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.primary,
                                ),
                          title: Text(
                            c.subscriptionName(item.url),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.error ??
                                {
                                  'queued': '等待导入',
                                  'loading': '正在展开仓库…',
                                  'ready': '${item.repositories} 个仓库 · 已保存',
                                  'existing': '已存在 · 已保留',
                                  'cancelled': '已取消',
                                }[item.status] ??
                                item.status,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (!widget.live &&
                c.subscriptions.any((s) => s.url != defaultSubscription))
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: waiting ? null : _clearOld,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清理旧订阅'),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已添加订阅 · ${widget.live ? liveUrls.length : userSubscriptions.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!widget.live && userSubscriptions.isNotEmpty)
                  TextButton.icon(
                    onPressed: waiting
                        ? null
                        : () => runUi(
                            context,
                            () => c.importSubscriptions(
                              userSubscriptions
                                  .map((item) => item.url)
                                  .where((url) => url.startsWith('http')),
                            ),
                          ),
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('全部刷新'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (widget.live) ...[
              if (liveUrls.isEmpty)
                const EmptyState(
                  title: '尚未添加直播订阅',
                  message: '添加自己的直播列表，或使用仓库内提供的直播源。',
                ),
              for (final url in liveUrls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.live_tv_outlined),
                      title: Text(
                        c.subscriptionName(url),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: '删除直播订阅',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (await confirm(context, '删除直播订阅？', url) &&
                              context.mounted) {
                            await runUi(context, () async {
                              await c.store.setSetting(
                                'liveSubscriptions',
                                liveUrls.where((item) => item != url).toList(),
                              );
                              c.refreshLibrary();
                              await c.loadLive();
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ),
            ] else ...[
              if (userSubscriptions.isEmpty)
                const EmptyState(title: '订阅列表为空', message: '输入一个地址，追加自己的视频订阅。'),
              for (final subscription in userSubscriptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: ExpansionTile(
                      leading: IconButton(
                        tooltip: '删除${c.subscriptionName(subscription.url)}',
                        onPressed: waiting
                            ? null
                            : () => _delete(subscription.url),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                      title: Text(
                        c.subscriptionName(subscription.url),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${subscription.configs.length} 个仓库 · ${subscription.nodes.length} 个节点',
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              TextButton.icon(
                                onPressed: waiting
                                    ? null
                                    : () => runUi(
                                        context,
                                        () => c.importSubscription(
                                          subscription.url,
                                        ),
                                      ),
                                icon: const Icon(Icons.refresh),
                                label: const Text('更新'),
                              ),
                              IconButton(
                                tooltip: '重命名订阅',
                                onPressed: waiting
                                    ? null
                                    : () => _rename(subscription.url),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: '分享订阅地址',
                                onPressed: () => _share(subscription.url),
                                icon: const Icon(Icons.ios_share),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: SelectableText(
                            subscription.url,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        for (final node in subscription.nodes) _node(node),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
  Widget _node(RepoNode node) => ListTile(
    dense: true,
    leading: Icon(
      node.error != null
          ? Icons.error_outline
          : node.config != null
          ? Icons.check_circle_outline
          : Icons.account_tree_outlined,
      color: node.error != null
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.primary,
    ),
    title: Text(node.config == null ? node.name : c.configName(node.config)),
    subtitle: SelectableText(
      '${node.status} · ${node.url}${node.error == null ? '' : '\n${node.error}'}',
    ),
    onTap: node.config == null
        ? null
        : () => runUi(context, () async {
            await c.selectConfig(node.config!);
            if (mounted) {
              showMessage(context, '已选择 ${c.configName(node.config)}');
            }
          }),
  );
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _scanner = MobileScannerController();
  bool _done = false;
  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('扫描订阅二维码'),
      actions: [
        IconButton(
          tooltip: '手电筒',
          onPressed: () => runUi(context, _scanner.toggleTorch),
          icon: const Icon(Icons.flash_on),
        ),
        IconButton(
          tooltip: '切换摄像头',
          onPressed: () => runUi(context, _scanner.switchCamera),
          icon: const Icon(Icons.cameraswitch),
        ),
      ],
    ),
    body: Stack(
      children: [
        MobileScanner(
          controller: _scanner,
          errorBuilder: (context, error) => Center(
            child: EmptyState(
              title: '摄像头不可用',
              message:
                  '${error.errorDetails?.message ?? error.errorCode.name}\n请检查相机权限，或返回手动输入。',
              icon: Icons.no_photography_outlined,
            ),
          ),
          onDetect: (capture) {
            if (_done) return;
            final value = capture.barcodes
                .map((barcode) => barcode.rawValue)
                .whereType<String>()
                .firstOrNull;
            if (value == null) return;
            final uri = Uri.tryParse(value);
            if (uri == null || !['http', 'https'].contains(uri.scheme)) return;
            _done = true;
            Navigator.pop(context, value);
          },
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '将 HTTP / HTTPS 订阅二维码放入画面\n扫描只填写地址，不会自动导入',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  backgroundColor: Colors.black54,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
