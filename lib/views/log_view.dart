import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../core/ui.dart';
import '../services/app_log_service.dart';

const _tabular = [FontFeature.tabularFigures()];

class LogView extends StatefulWidget {
  const LogView({super.key});

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _logs = Get.find<AppLogService>();
  final _filter = '全部'.obs;

  static const _filters = [
    ('全部', '全部'),
    ('错误', '错误'),
    ('警告', '警告'),
    ('信息', '信息'),
    ('调试', '调试'),
  ];

  Future<void> _copy() async {
    await _logs.copyImportantLogs();
    if (!mounted) return;
    showToast('已复制', '重要日志已复制到剪贴板。',
        tone: ToastTone.success);
  }

  Future<void> _clear() async {
    final ok = await confirmSheet(
      context,
      title: '清空日志？',
      message: '所有已捕获的日志条目都将被删除。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (ok) _logs.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: '日志',
        showBack: true,
        actions: [
          Obx(() => AppBarIcon(
                icon: Icons.copy_rounded,
                tooltip: '复制重要日志',
                onPressed: _logs.entries.isEmpty ? null : _copy,
              )),
          Obx(() => AppBarIcon(
                icon: Icons.delete_outline_rounded,
                tooltip: '清空日志',
                onPressed: _logs.entries.isEmpty ? null : _clear,
              )),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 10),
          child: Obx(() => AppChips<String>(
                items: _filters,
                selected: _filter.value,
                onSelected: (v) => _filter.value = v,
              )),
        ),
        Container(height: 0.5, color: t.hairline),
        Expanded(
          child: Obx(() {
            final all = _logs.entries;
            final f = _filter.value;
            final filtered = f == '全部'
                ? all.toList()
                : all.where((e) => e.level == f).toList();

            if (filtered.isEmpty) {
              final label = _filters.firstWhere((e) => e.$1 == f).$2;
              return Center(
                child: SingleChildScrollView(
                  child: EmptyState(
                    icon: Icons.check_rounded,
                    title: f == '全部'
                        ? '暂无日志'
                        : '暂无${label.toLowerCase()}',
                    message: f == '全部'
                        ? '错误、警告和调试详情会显示在这里。'
                        : '尚未捕获此级别的任何内容。',
                  ),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Container(height: 0.5, color: t.hairline),
              ),
              itemBuilder: (context, index) =>
                  _LogEntryTile(entry: filtered[index]),
            );
          }),
        ),
      ]),
    );
  }
}

class _LogEntryTile extends StatefulWidget {
  final AppLogEntry entry;
  const _LogEntryTile({required this.entry});

  @override
  State<_LogEntryTile> createState() => _LogEntryTileState();
}

class _LogEntryTileState extends State<_LogEntryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final e = widget.entry;
    final hasDetails = e.details != null && e.details!.trim().isNotEmpty;

    final (String levelLabel, Color? levelColor) = switch (e.level) {
      '错误' => ('错误', t.red),
      '警告' => ('警告', t.orange),
      '信息' => ('信息', null),
      '调试' => ('调试', null),
      _ => (e.level, null),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppTag(levelLabel, color: levelColor),
          const SizedBox(width: 8),
          Text(_formatTime(e.timestamp),
              style: t.small.copyWith(fontFeatures: _tabular)),
        ]),
        const SizedBox(height: 6),
        SelectableText(e.message, style: t.body.copyWith(fontSize: 14)),
        if (hasDetails) ...[
          const SizedBox(height: 6),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            splashFactory: NoSplash.splashFactory,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_expanded ? '隐藏详情' : '显示详情',
                    style: t.small.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child:
                      Icon(Icons.expand_more_rounded, size: 16, color: t.muted),
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.hairline, width: 0.5),
                    ),
                    child: SelectableText(e.details!,
                        style: t.mono.copyWith(
                            fontSize: 11.5, color: t.muted, height: 1.45)),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ]),
    );
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
