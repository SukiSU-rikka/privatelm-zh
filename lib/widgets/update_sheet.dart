import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/ui.dart';
import '../services/update_service.dart';
import 'chat_bubble.dart';

/// "有可用更新" sheet: release notes, then download progress and the
/// hand-off to the system installer.
class UpdateSheet extends StatelessWidget {
  const UpdateSheet({super.key});

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final updates = Get.find<UpdateService>();
    return Obx(() {
      final release = updates.availableUpdate.value;
      if (release == null) return const SizedBox.shrink();
      final state = updates.state.value;
      final downloading = state == UpdateState.downloading;
      final installing = state == UpdateState.installing;

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconBadge(Icons.system_update_rounded, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('有可用更新',
                  style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      color: t.text)),
              const SizedBox(height: 2),
              Text(
                  'PrivateLM ${release.version}'
                  '${release.apkSize > 0 ? ' · ${_mb(release.apkSize)}' : ''}'
                  '${updates.currentVersion.value.isNotEmpty ? ' · 你当前的是 ${updates.currentVersion.value}' : ''}',
                  style: t.caption),
            ]),
          ),
        ]),
        if (release.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            constraints: const BoxConstraints(maxHeight: 280),
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            decoration: BoxDecoration(
              color: t.fill,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: MarkdownBody(
                data: release.notes,
                styleSheet: ChatBubble.answerStyle(context).copyWith(
                  p: t.caption.copyWith(color: t.text, height: 1.45),
                  strong: t.caption.copyWith(
                      color: t.text, height: 1.45, fontWeight: FontWeight.w600),
                  em: t.caption.copyWith(
                      color: t.text, height: 1.45, fontStyle: FontStyle.italic),
                  listBullet: t.caption.copyWith(color: t.text),
                  h2: t.bodyStrong,
                  h3: t.bodyStrong.copyWith(fontSize: 14),
                  blockquoteDecoration: BoxDecoration(
                    color: t.orange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (updates.needsInstallPermission.value) ...[
          const AppNotice(
            '请允许 PrivateLM 安装应用，然后回来。'
            '安装器会自动打开。',
            icon: Icons.lock_open_rounded,
          ),
          const SizedBox(height: 12),
        ],
        if (state == UpdateState.error &&
            updates.lastError.value.isNotEmpty) ...[
          AppNotice(updates.lastError.value,
              icon: Icons.error_outline_rounded, color: t.red),
          const SizedBox(height: 12),
        ],
        if (release.apkUrl == null)
          AppNotice(
              '此版本中没有适用于本设备的 APK。请从 GitHub 下载：${release.pageUrl}')
        else if (downloading) ...[
          AppProgressBar(
              value:
                  updates.progress.value > 0 ? updates.progress.value : null),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(
                  updates.totalBytes.value > 0
                      ? '${_mb(updates.downloadedBytes.value)} of ${_mb(updates.totalBytes.value)}'
                      : '正在开始下载…',
                  style: t.caption),
            ),
            PillButton(label: '取消', onPressed: updates.cancelDownload),
          ]),
        ] else ...[
          PrimaryButton(
            label: installing ? '正在打开安装器…' : '下载并安装',
            icon: Icons.download_rounded,
            busy: installing,
            onPressed: updates.downloadAndInstall,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TonalButton.neutral(context, label: '跳过此版本',
                  onTap: () {
                updates.skipVersion(release.version);
                Navigator.pop(context);
              }),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TonalButton.neutral(context,
                  label: '稍后', onTap: () => Navigator.pop(context)),
            ),
          ]),
        ],
      ]);
    });
  }
}
