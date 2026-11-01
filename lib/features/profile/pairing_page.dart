import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../ui/components.dart';

class PairingPage extends StatelessWidget {
  const PairingPage({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final pairing = controller.pairing;
    return ListenableBuilder(
      listenable: pairing,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('局域网数据推送')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.devices,
                      size: 36,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '让输入更轻松',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '在同一 Wi-Fi 的电脑或手机上打开配对地址，输入临时验证码，发送订阅链接。每条推送都需要在本机确认。\n\n服务默认关闭，仅绑定局域网，开启 10 分钟后自动结束。不会自动播放，也不接受脚本或文件。',
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: pairing.accepting
                          ? null
                          : () => runUi(
                              context,
                              pairing.running ? pairing.stop : pairing.start,
                            ),
                      icon: Icon(
                        pairing.running
                            ? Icons.stop_circle_outlined
                            : Icons.wifi,
                      ),
                      label: Text(pairing.running ? '关闭推送服务' : '开启临时配对'),
                    ),
                  ],
                ),
              ),
            ),
            if (pairing.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ErrorNotice(error: pairing.error!),
              ),
            if (pairing.running) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '配对地址',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final address in pairing.addresses)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: SelectableText(address),
                          trailing: IconButton(
                            tooltip: '复制配对地址',
                            icon: const Icon(Icons.copy),
                            onPressed: () => runUi(context, () async {
                              await Clipboard.setData(
                                ClipboardData(text: address),
                              );
                              if (context.mounted) {
                                showMessage(context, '地址已复制');
                              }
                            }),
                          ),
                        ),
                      Text(
                        '临时验证码',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        pairing.code ?? '',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              letterSpacing: 8,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '有效至 ${pairing.expiresAt?.toLocal().toString().substring(0, 19) ?? '—'}',
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (pairing.pending case final request?) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '待确认的订阅',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      SelectableText(request.url),
                      const SizedBox(height: 8),
                      Text('来自 ${request.remoteAddress}'),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          TextButton(
                            onPressed: pairing.accepting
                                ? null
                                : pairing.rejectPending,
                            child: const Text('拒绝'),
                          ),
                          const Spacer(),
                          FilledButton(
                            onPressed: pairing.accepting
                                ? null
                                : () => runUi(context, pairing.approvePending),
                            child: Text(pairing.accepting ? '正在导入…' : '确认导入'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
