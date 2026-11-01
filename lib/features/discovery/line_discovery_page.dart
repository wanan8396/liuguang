import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/discovery/line_scanner.dart';
import '../../ui/components.dart';

class LineDiscoveryPage extends StatefulWidget {
  const LineDiscoveryPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<LineDiscoveryPage> createState() => _LineDiscoveryPageState();
}

class _LineDiscoveryPageState extends State<LineDiscoveryPage> {
  final _scanner = LineScanner();
  ScanProgress? _progress;
  final _selected = <String>{};
  String _query = '';
  String _speed = '';
  String _kind = '';
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _scanner.onProgress = (value) {
      if (mounted) setState(() => _progress = value);
    };
  }

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  List<ScanNode> get _results => discoveryResults(_scanner.roots);
  List<ScanNode> get _leaves =>
      _results
          .where((n) => n.available && !(n.multi && n.children.isNotEmpty))
          .toList()
        ..sort((a, b) => a.totalMs.compareTo(b.totalMs));
  List<ScanNode> get _visible {
    final results = _results;
    return results.where((node) {
      if (_query.isNotEmpty) {
        final text = '${node.name} ${node.url}'.toLowerCase();
        if (!text.contains(_query.toLowerCase())) return false;
      }
      if (_speed.isNotEmpty && node.speedLabel != _speed) return false;
      if (_kind.isNotEmpty && node.kindLabel != _kind) return false;
      return true;
    }).toList();
  }

  Future<void> _scan() async {
    _selected.clear();
    setState(
      () => _progress = const ScanProgress(stage: '准备中', done: 0, total: 0),
    );
    await _scanner.start();
    if (!mounted) return;
    setState(() {});
    final leaves = _leaves;
    if (leaves.isNotEmpty) {
      // 默认勾选最快的一批可用线路，避免用户手工挑几十条。
      _selected.addAll(leaves.take(5).map((n) => n.url));
      setState(() {});
    }
  }

  Future<void> _import() async {
    final chosen = _leaves.where((n) => _selected.contains(n.url)).toList();
    if (chosen.isEmpty) {
      showMessage(context, '请先选择至少一条可用线路');
      return;
    }
    setState(() => _importing = true);
    try {
      final text = buildImportConfig(chosen, name: '线路发现 ${chosen.length} 条');
      await widget.controller.importText(text, name: '线路发现 ${chosen.length} 条');
      if (!mounted) return;
      showMessage(context, '已导入 ${chosen.length} 条线路');
      Navigator.pop(context);
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = _scanner.running;
    final visible = _visible;
    final leaves = _leaves;
    final available = leaves.length;
    final selectedCount = _selected.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('线路发现'),
        actions: [
          if (available > 0)
            TextButton(
              onPressed: selectedCount == leaves.length
                  ? () => setState(_selected.clear)
                  : () => setState(
                      () => _selected
                        ..clear()
                        ..addAll(leaves.map((n) => n.url)),
                    ),
              child: Text(selectedCount == leaves.length ? '取消全选' : '全选'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _progress!.stage,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _progress!.total > 0
                            ? '${_progress!.done}/${_progress!.total}'
                            : '',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: _progress!.total > 0
                          ? (_progress!.done / _progress!.total).clamp(0, 1)
                          : null,
                    ),
                  ),
                  if (_progress!.info.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _progress!.info,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: running
                    ? () {
                        _scanner.cancel();
                        setState(() {});
                      }
                    : _importing
                    ? null
                    : _scan,
                icon: Icon(running ? Icons.stop : Icons.travel_explore),
                label: Text(
                  running
                      ? '停止扫描'
                      : _scanner.roots.isEmpty
                      ? '全网搜索并测速'
                      : '重新扫描',
                ),
              ),
            ),
          ),
          if (_results.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '筛选名称或地址',
                  isDense: true,
                  prefixIcon: Icon(Icons.filter_alt_outlined, size: 18),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _speed,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: '速度',
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('全部')),
                        DropdownMenuItem(value: '快', child: Text('快 <500ms')),
                        DropdownMenuItem(value: '中', child: Text('中 <2s')),
                        DropdownMenuItem(value: '慢', child: Text('慢 <5s')),
                      ],
                      onChanged: (value) =>
                          setState(() => _speed = value ?? ''),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _kind,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: '类型',
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('全部')),
                        DropdownMenuItem(value: '单仓', child: Text('单仓')),
                        DropdownMenuItem(value: '多仓', child: Text('多仓')),
                      ],
                      onChanged: (value) => setState(() => _kind = value ?? ''),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Text(
                    '可用 $available · 显示 ${visible.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '已选 $selectedCount',
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                ],
              ),
            ),
          ],
          Expanded(
            child: _scanner.roots.isEmpty
                ? Center(
                    child: EmptyState(
                      title: running ? '正在搜索线路' : '还没有扫描',
                      message: running
                          ? '并发探测公开仓库地址，测速并验证配置结构。'
                          : '点击上方按钮，从公开入口搜索影视仓线路并实测速度。\n只导入你信任的线路。',
                      icon: Icons.travel_explore,
                    ),
                  )
                : visible.isEmpty
                ? const Center(
                    child: EmptyState(
                      title: '没有匹配的线路',
                      message: '调整筛选条件，或重新扫描。',
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final node = visible[index];
                      final checked = _selected.contains(node.url);
                      return Card(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap:
                              !node.available ||
                                  (node.multi && node.children.isNotEmpty)
                              ? null
                              : () => setState(() {
                                  if (!_selected.remove(node.url)) {
                                    _selected.add(node.url);
                                  }
                                }),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: checked,
                                  onChanged:
                                      !node.available ||
                                          (node.multi &&
                                              node.children.isNotEmpty)
                                      ? null
                                      : (value) => setState(() {
                                          if (value ?? false) {
                                            _selected.add(node.url);
                                          } else {
                                            _selected.remove(node.url);
                                          }
                                        }),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              node.name.trim().isEmpty
                                                  ? node.url
                                                  : node.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          _SpeedBadge(
                                            label: node.speedLabel,
                                            ms: node.totalMs,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        node.url,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          _Chip(text: node.kindLabel),
                                          _Chip(
                                            text: node.available
                                                ? '可用'
                                                : node.status == 'pending'
                                                ? '待检测'
                                                : '不可用${node.error == null ? '' : '：${node.error}'}',
                                          ),
                                          if (node.note.isNotEmpty)
                                            _Chip(text: node.note),
                                          if (node.siteCount > 0)
                                            _Chip(text: '${node.siteCount} 站点'),
                                          if (node.totalMs >= 0)
                                            _Chip(text: '${node.totalMs}ms'),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: leaves.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: _importing || selectedCount == 0 ? null : _import,
                  child: Text(_importing ? '导入中…' : '导入所选 $selectedCount 条线路'),
                ),
              ),
            ),
    );
  }
}

class _SpeedBadge extends StatelessWidget {
  const _SpeedBadge({required this.label, required this.ms});
  final String label;
  final int ms;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      '快' => const Color(0xFF16A34A),
      '中' => const Color(0xFFD97706),
      _ => const Color(0xFF6B7280),
    };
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: .6),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// 显示所有已发现的节点，包括多仓容器及未检测或失败的节点。
List<ScanNode> discoveryResults(Iterable<ScanNode> roots) {
  final out = <ScanNode>[];
  void walk(ScanNode node) {
    out.add(node);
    for (final child in node.children) {
      walk(child);
    }
  }

  for (final root in roots) {
    walk(root);
  }
  return out;
}
