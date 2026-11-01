import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';

class SourceManagementPage extends StatefulWidget {
  const SourceManagementPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<SourceManagementPage> createState() => _SourceManagementPageState();
}

class _SourceManagementPageState extends State<SourceManagementPage> {
  TvConfig? _selected;
  Future<List<String>>? _credentials;
  List<Site> _sites = [];
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    _select(c.currentConfig ?? c.configs.firstOrNull);
  }

  void _select(TvConfig? config) {
    _selected = config;
    if (config == null) return;
    final order = jsonList(
      c.store.setting('siteOrder:${config.url}'),
    ).map(str).toList();
    _sites = config.sites
      ..sort((a, b) {
        final ai = order.indexOf(a.key), bi = order.indexOf(b.key);
        return (ai < 0 ? order.length : ai).compareTo(
          bi < 0 ? order.length : bi,
        );
      });
    _credentials = c.credentialNames(config: config);
  }

  Future<void> _credential([String? existing]) async {
    final name = TextEditingController(text: existing ?? '');
    final value = TextEditingController();
    final form = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '添加源凭据' : '更新源凭据'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '名称必须与源的 /file/<name> 引用一致，例如 quark_cookie.txt。内容加密保存，不包含在备份中。',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: name,
                readOnly: existing != null,
                decoration: const InputDecoration(labelText: '文件名'),
                validator: (text) =>
                    RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(text ?? '')
                    ? null
                    : '仅限 1–64 位字母、数字、_、.、-',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: value,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Cookie / Token（不回显现值）',
                ),
                validator: (text) =>
                    text?.isNotEmpty == true ? null : '请输入新的凭据内容',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final credentialName = name.text, credentialValue = value.text;
    name.dispose();
    value.dispose();
    if (result == true && mounted) {
      await runUi(context, () async {
        await c.saveCredential(
          credentialName,
          credentialValue,
          config: _selected,
        );
        setState(() => _credentials = c.credentialNames(config: _selected));
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('源管理与凭据')),
      body: c.configs.isEmpty
          ? const Center(
              child: EmptyState(title: '暂无可管理的仓库', message: '请先添加视频订阅。'),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _selected?.url,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '管理仓库'),
                  items: [
                    for (final config in c.configs)
                      DropdownMenuItem(
                        value: config.url,
                        child: Text(
                          config.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (url) => setState(
                    () => _select(
                      c.configs.firstWhere((config) => config.url == url),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('站点启停与排序', style: Theme.of(context).textTheme.titleMedium),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('拖动右侧手柄排序。聚合搜索和源选择只使用已启用站点。'),
                ),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _sites.length,
                  onReorderItem: (oldIndex, newIndex) async {
                    setState(() {
                      final site = _sites.removeAt(oldIndex);
                      _sites.insert(newIndex, site);
                    });
                    await runUi(
                      context,
                      () => c.reorderSites(
                        _sites.map((site) => site.key).toList(),
                        config: _selected,
                      ),
                    );
                  },
                  itemBuilder: (context, index) {
                    final site = _sites[index];
                    return SwitchListTile(
                      key: ValueKey(site.key),
                      title: Text(site.name),
                      subtitle: Text(site.runtime.toUpperCase()),
                      value: c.isSiteEnabled(site, _selected),
                      onChanged: (enabled) => runUi(
                        context,
                        () =>
                            c.setSiteEnabled(site, enabled, config: _selected),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Text('源凭据', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _credential,
                      icon: const Icon(Icons.add),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                Card(
                  child: FutureBuilder<List<String>>(
                    future: _credentials,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return ErrorNotice(error: '${snapshot.error}');
                      }
                      if (!snapshot.hasData) {
                        return const LinearProgressIndicator();
                      }
                      if (snapshot.data!.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '没有已保存凭据。需要登录的网盘源可在此填写自己的 Cookie / Token。',
                          ),
                        );
                      }
                      return Column(
                        children: [
                          for (final name in snapshot.data!)
                            ListTile(
                              leading: const Icon(Icons.key_outlined),
                              title: Text(name),
                              subtitle: const Text('内容已加密 · 点击更新'),
                              onTap: () => _credential(name),
                              trailing: IconButton(
                                tooltip: '删除凭据',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  if (await confirm(context, '删除凭据？', name) &&
                                      context.mounted) {
                                    await runUi(context, () async {
                                      await c.saveCredential(
                                        name,
                                        '',
                                        config: _selected,
                                      );
                                      setState(
                                        () => _credentials = c.credentialNames(
                                          config: _selected,
                                        ),
                                      );
                                    });
                                  }
                                },
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    ),
  );
}
