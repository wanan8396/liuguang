import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';
import '../discovery/line_discovery_page.dart';

const defaultSubscription = 'http://z.qiqiv.cn/123.txt';

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
  late final TextEditingController _url = TextEditingController(
    text: widget.live ? '' : defaultSubscription,
  );
  bool _working = false;
  AppController get c => widget.controller;
  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      showMessage(context, '请输入有效的 HTTP / HTTPS 订阅地址');
      return;
    }
    setState(() => _working = true);
    await runUi(context, () async {
      if (widget.live) {
        await c.addLiveSubscription(uri.toString());
      } else {
        await c.importSubscription(uri.toString());
      }
      if (mounted) showMessage(context, '订阅已处理，请查看节点状态');
    });
    if (mounted) setState(() => _working = false);
  }

  Future<void> _scan() async {
    final value = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (value != null && mounted) setState(() => _url.text = value);
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
      final waiting = _working || c.importing;
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
                tooltip: '全网发现线路',
                onPressed: waiting
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              LineDiscoveryPage(controller: c),
                        ),
                      ),
                icon: const Icon(Icons.travel_explore),
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
                      widget.live ? '添加直播列表' : '添加视频订阅',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.live
                          ? '支持 M3U、TXT 和 JSON 多线路列表'
                          : '支持多仓入口与单仓配置，自动展开并保留节点诊断',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _url,
                      enabled: !waiting,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        hintText: 'http(s)://…',
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
                            label: Text(waiting ? '导入中…' : '添加订阅'),
                          ),
                        ),
                        if (c.importing)
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
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ErrorNotice(error: c.error!),
              ),
            if (c.importNodes.isNotEmpty && !widget.live) ...[
              const SizedBox(height: 16),
              ExpansionTile(
                title: Text('最近导入诊断 · ${c.importNodes.length} 个节点'),
                children: [for (final node in c.importNodes) _node(node)],
              ),
            ],
            const SizedBox(height: 20),
            Text('已添加订阅', style: Theme.of(context).textTheme.titleMedium),
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
                        url,
                        maxLines: 2,
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
              if (c.subscriptions.isEmpty)
                const EmptyState(
                  title: '订阅列表为空',
                  message: '上方已预填入口地址，可修改后点击添加。不会自动请求或运行插件。',
                ),
              for (final subscription in c.subscriptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: ExpansionTile(
                      title: Text(
                        subscription.url,
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
                                tooltip: '分享订阅地址',
                                onPressed: () => _share(subscription.url),
                                icon: const Icon(Icons.ios_share),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: '移除订阅',
                                onPressed: () async {
                                  if (await confirm(
                                        context,
                                        '移除订阅？',
                                        '收藏与历史会保留，但原内容源可能不再可用。',
                                      ) &&
                                      context.mounted) {
                                    await runUi(
                                      context,
                                      () => c.removeSubscription(
                                        subscription.url,
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
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
    title: Text(node.name),
    subtitle: SelectableText(
      '${node.status} · ${node.url}${node.error == null ? '' : '\n${node.error}'}',
    ),
    onTap: node.config == null
        ? null
        : () => runUi(context, () async {
            await c.selectConfig(node.config!);
            if (mounted) showMessage(context, '已选择 ${node.config!.name}');
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
