import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../widgets/home_empty_state.dart' show providerLabel;
import '../services/inference_service.dart';
import '../services/hive_service.dart';
import '../services/local_image_service.dart';
import '../services/update_service.dart';
import '../services/device_info_service.dart';
import '../services/device_info_native.dart' as platform_info;
import '../ffi/sd_ffi_bindings.dart';
import '../services/cluster_service.dart';
import 'cluster_view.dart';
import 'log_view.dart';
import '../core/haptics.dart';

const _tabular = [FontFeature.tabularFigures()];

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: '设置'),
      body: Obx(() {
        final device = Get.find<DeviceInfoService>();
        final showUpdates =
            UpdateService.isSupported && Get.isRegistered<UpdateService>();
        return ListView(
          padding: kPagePadding,
          children: [
            const SectionHeader('通用',
                padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.palette_outlined,
                title: '外观',
                value: _themeLabel(),
                builder: (ctx) => _buildAppearanceGroup(ctx),
              ),
              AppRow(
                icon: Icons.vibration_rounded,
                title: '触感反馈',
                trailing: Switch(
                  value: controller.hapticsEnabled.value,
                  onChanged: controller.setHapticsEnabled,
                ),
                onTap: () => controller
                    .setHapticsEnabled(!controller.hapticsEnabled.value),
              ),
            ]),
            const SectionHeader('聊天'),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.memory_rounded,
                title: '推理模式',
                value: controller.inferenceMode.value == 'local'
                    ? '本地'
                    : '云端',
                builder: (ctx) => _buildInferenceGroup(ctx),
              ),
              _navRow(
                context,
                icon: Icons.chat_bubble_outline_rounded,
                title: '系统提示词',
                value: controller.globalSystemPrompt.value.trim().isEmpty
                    ? '默认'
                    : '自定义',
                builder: (ctx) => _buildSystemPromptGroup(ctx),
                reactive: false,
              ),
              _navRow(
                context,
                icon: Icons.tune_rounded,
                title: '模型参数',
                value: controller.temperature.value.toStringAsFixed(2),
                builder: (ctx) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildModelParametersGroup(ctx),
                      const SectionHeader('停止序列'),
                      _buildStopSequencesGroup(ctx),
                    ]),
              ),
            ]),
            const SectionHeader('性能'),
            AppGroup(dividerIndent: 60, children: [
              _navRow(
                context,
                icon: Icons.speed_rounded,
                title: 'GGUF & LiteRT',
                value: switch (controller.liteRtPerformanceMode.value) {
                  'gpu_fast' => 'GPU 快速',
                  'cpu_safe' => 'CPU 安全',
                  _ => '自动快速',
                },
                builder: (ctx) => _buildLiteRtGroup(ctx),
              ),
              _navRow(
                context,
                icon: Icons.image_outlined,
                title: '图片生成',
                value: controller.imageGenBackend.value == Backend.cpu
                    ? 'CPU'
                    : 'GPU',
                builder: (ctx) => _buildImageGenerationGroup(ctx),
              ),
              if (Get.isRegistered<ClusterService>())
                AppRow(
                  icon: Icons.hub_outlined,
                  title: '手机集群',
                  trailing: Text(
                      switch (Get.find<ClusterService>().role) {
                        ClusterRole.master => '主机',
                        ClusterRole.worker => '工作节点',
                        ClusterRole.off => '关',
                      },
                      style: AppTokens.of(context).caption.copyWith(fontSize: 14)),
                  chevron: true,
                  onTap: () => Get.to(() => const ClusterView()),
                ),
            ]),
            const SectionHeader('关于'),
            AppGroup(dividerIndent: 60, children: [
              if (showUpdates) _buildUpdatesRow(context),
              _navRow(
                context,
                icon: Icons.smartphone_rounded,
                title: '设备',
                value: '${device.totalRamGB.value.toStringAsFixed(1)} GB RAM',
                builder: (ctx) => AppGroup(children: [_buildDeviceCard(ctx)]),
                reactive: false,
              ),
              AppRow(
                icon: Icons.article_outlined,
                title: '日志',
                chevron: true,
                onTap: () => Get.to(() => const LogView()),
              ),
              AppRow(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icons/appicon.png',
                      width: 32, height: 32),
                ),
                title: 'PrivateLM',
                subtitle: controller.appVersion.value.isEmpty
                    ? 'by orailnoor & techjarves'
                    : 'Version ${controller.appVersion.value} · by orailnoor & techjarves',
              ),
            ]),
          ],
        );
      }),
    );
  }

  /// Row on the main page: icon, title, current value and a chevron that
  /// opens the section on its own page.
  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required WidgetBuilder builder,
    bool reactive = true,
  }) {
    final t = AppTokens.of(context);
    return AppRow(
      icon: icon,
      title: title,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(fontSize: 14)),
      ),
      chevron: true,
      onTap: () => Get.to(() =>
          _SettingsPage(title: title, builder: builder, reactive: reactive)),
    );
  }

  String _themeLabel() => switch (controller.themeMode.value) {
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
        ThemeMode.system => '跟随系统',
      };

  Widget _buildAppearanceGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return AppGroup(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('主题', style: t.body),
          const SizedBox(height: 10),
          AppSegmented<ThemeMode>(
            items: const [
              (ThemeMode.light, '浅色'),
              (ThemeMode.dark, '深色'),
              (ThemeMode.system, '跟随系统'),
            ],
            selected: controller.themeMode.value,
            onChanged: (mode) {
              if (mode != controller.themeMode.value) {
                controller.setThemeMode(mode);
              }
            },
          ),
        ]),
      ),
      _buildFontSizeRow(context),
    ]);
  }

  Widget _buildInferenceGroup(BuildContext context) {
    return AppGroup(dividerIndent: 60, children: [
      AppRow(
        icon: Icons.phone_iphone_rounded,
        title: '本地（设备端）',
        subtitle: _localSubtitle(),
        selected: controller.inferenceMode.value == 'local',
        onTap: () => controller.setInferenceMode('local'),
      ),
      AppRow(
        icon: Icons.cloud_outlined,
        title: '云端 API',
        subtitle: providerLabel(controller),
        selected: controller.inferenceMode.value == 'cloud',
        onTap: () => controller.setInferenceMode('cloud'),
      ),
    ]);
  }

  Widget _buildSystemPromptGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      TextField(
        controller: controller.globalSystemPromptController,
        minLines: 5,
        maxLines: 12,
        style: t.body,
        decoration:
            appInputDecoration(context, hint: AppConstants.systemPrompt),
        onSubmitted: (v) => controller.setGlobalSystemPrompt(v),
      ),
      _fieldFooter(
        context,
        note: '适用于本地和云端模型。',
        onSave: () async {
          await controller.setGlobalSystemPrompt(
              controller.globalSystemPromptController.text);
          if (context.mounted) {
            _confirmSaved(context, '系统提示词已保存');
          }
        },
      ),
    ]);
  }

  Widget _buildStopSequencesGroup(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      TextField(
        controller: controller.stopSequencesController,
        minLines: 2,
        maxLines: 5,
        style: t.mono.copyWith(fontSize: 13.5),
        decoration: appInputDecoration(context, hint: '###\n\\nUser:'),
      ),
      _fieldFooter(
        context,
        note: 'Local models stop when they write one of these. '
            'One per line; use \\n for a newline.',
        onSave: () async {
          await controller
              .setStopSequences(controller.stopSequencesController.text);
          if (context.mounted) {
            _confirmSaved(context, '停止序列已保存');
          }
        },
      ),
    ]);
  }

  Widget _buildUpdatesRow(BuildContext context) {
    final updates = Get.find<UpdateService>();
    final t = AppTokens.of(context);
    final update = updates.availableUpdate.value;
    final downloading = updates.state.value == UpdateState.downloading;
    return AppRow(
      icon: Icons.system_update_rounded,
      title: '应用更新',
      trailing: update != null
          ? AppTag(
              downloading
                  ? '${(updates.progress.value * 100).round()}%'
                  : '新版本 ${update.version} 可用',
              color: t.accent)
          : Text('已是最新', style: t.caption.copyWith(fontSize: 14)),
      chevron: true,
      onTap: () => Get.to(() => _SettingsPage(
          title: '应用更新', builder: (ctx) => _buildUpdatesGroup(ctx))),
    );
  }

  Widget _buildUpdatesGroup(BuildContext context) {
    final updates = Get.find<UpdateService>();
    final update = updates.availableUpdate.value;
    final checking = updates.state.value == UpdateState.checking;
    final checked = updates.lastCheck.value;
    final current = updates.currentVersion.value;
    final String status;
    if (update != null) {
      status = 'You have $current · see what\'s new';
    } else if (checked != null) {
      status = 'Up to date · checked ${_ago(checked)}';
    } else {
      status = 'Not checked yet';
    }
    return AppGroup(dividerIndent: 60, children: [
      AppRow(
        icon: update != null ? Icons.download_rounded : Icons.refresh_rounded,
        title: update != null
            ? '更新到 ${update.version}'
            : '检查更新',
        subtitle: status,
        trailing: checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        chevron: !checking,
        onTap: checking
            ? null
            : () async {
                if (update != null) {
                  updates.showUpdateSheet(context);
                  return;
                }
                final found = await updates.checkForUpdate(manual: true);
                if (found != null && context.mounted) {
                  updates.showUpdateSheet(context);
                }
              },
      ),
      AppRow(
        icon: Icons.schedule_rounded,
        title: '自动检查',
        subtitle: '每天检查一次新版本',
        trailing: Switch(
          value: updates.autoCheck.value,
          onChanged: updates.setAutoCheck,
        ),
        onTap: () => updates.setAutoCheck(!updates.autoCheck.value),
      ),
    ]);
  }

  static String _ago(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  // ── Building blocks ─────────────────────────────────────────────────────

  /// Note on the left, explicit Save on the right, under a text field.
  Widget _fieldFooter(BuildContext context,
      {required String note, required VoidCallback onSave}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(note, style: t.small),
          ),
        ),
        const SizedBox(width: 12),
        PillButton(label: '保存', primary: true, onPressed: onSave),
      ]),
    );
  }

  void _confirmSaved(BuildContext context, String message) {
    FocusScope.of(context).unfocus();
    showToast('已保存', message, tone: ToastTone.success);
  }

  /// Consistent slider row: label left, value right, slider below, then an
  /// optional caption and trailing widget (e.g. a warning notice).
  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
    Color? color,
    String? caption,
    List<Widget> below = const [],
  }) {
    final t = AppTokens.of(context);
    final c = color ?? t.accent;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Text(label, style: t.body)),
            const SizedBox(width: 12),
            Text(valueLabel,
                style: t.body.copyWith(
                    color: color ?? t.muted,
                    fontWeight: color != null ? FontWeight.w600 : null,
                    fontFeatures: _tabular)),
          ]),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: c,
            inactiveTrackColor: t.fill,
            thumbColor: Colors.white,
            overlayColor: c.withValues(alpha: 0.12),
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 10, elevation: 2),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(caption, style: t.small),
          ),
        for (final w in below)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: w,
          ),
      ]),
    );
  }

  // ── Sections ────────────────────────────────────────────────────────────

  String _localSubtitle() {
    final inf = Get.find<InferenceService>();
    final localImage = Get.find<LocalImageService>();
    if (inf.isModelLoaded.value) {
      return '使用中：${inf.loadedModelName.value}';
    } else if (localImage.isModelLoaded.value) {
      return '使用中：${localImage.loadedModelName.value}';
    }
    return '未加载模型';
  }

  Widget _buildFontSizeRow(BuildContext context) {
    final t = AppTokens.of(context);
    const min = 0.8;
    const max = 1.4;
    final v = controller.fontScale.value;

    String scaleLabel(double v) {
      if (v <= 0.85) return 'XS';
      if (v <= 0.95) return '小';
      if (v <= 1.05) return '推荐';
      if (v <= 1.15) return '大';
      if (v <= 1.25) return 'XL';
      return 'XXL';
    }

    final isDefault = v >= 0.9 && v <= 0.95;
    Widget marker(String s, {bool on = false}) => Text(s,
        style: t.small.copyWith(
            fontSize: 11,
            color: on ? t.text : t.faint,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400));

    return _sliderRow(
      context,
      label: '文字大小',
      valueLabel: scaleLabel(v),
      value: v,
      min: min,
      max: max,
      divisions: 12,
      onChanged: (v) => controller.setFontScale(v),
      below: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          marker('XS'),
          marker('小（默认）', on: isDefault),
          marker('大'),
        ]),
      ],
    );
  }

  Widget _buildDeviceCard(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      final device = Get.find<DeviceInfoService>();
      final ram = device.totalRamGB.value.toStringAsFixed(1);
      final (String tierName, String tierHint) =
          switch (device.deviceTier.value) {
        'low' => ('低内存', '仅使用小模型'),
        'mid' => ('中端', '适合 1–3B 模型'),
        'high' => ('高端', '可运行 3–7B 模型'),
        'ultra' => ('极高', '全性能模式'),
        _ => ('', ''),
      };
      final isLow = device.deviceTier.value == 'low';

      final soc = device.socFamily.value;
      final quantWarning = soc.quantWarning;

      Widget kv(String k, String v, {Color? color}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Text(k, style: t.caption.copyWith(fontSize: 14)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(v,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(
                        fontSize: 14,
                        color: color ?? t.text,
                        fontFeatures: _tabular)),
              ),
            ]),
          );

      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const IconBadge(Icons.smartphone_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$ram GB RAM',
                        style: t.bodyStrong.copyWith(fontFeatures: _tabular)),
                    if (tierHint.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(tierHint, style: t.caption),
                    ],
                  ]),
            ),
            if (tierName.isNotEmpty) ...[
              const SizedBox(width: 10),
              AppTag(tierName, color: isLow ? t.orange : null),
            ],
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(height: 0.5, color: t.hairline),
          ),
          kv('可用内存',
              '${device.availableRamGB.value.toStringAsFixed(1)} GB'),
          kv('推荐上下文', '${device.recommendedContextSize}'),
          kv('推荐最大 Token 数', '${device.recommendedMaxTokens}'),
          if (soc != platform_info.SocFamily.unknown) ...[
            kv('芯片', soc.displayName),
            kv('推荐量化', soc.recommendedQuant,
                color: quantWarning != null ? t.orange : null),
          ],
          if (quantWarning != null) ...[
            const SizedBox(height: 10),
            AppNotice(quantWarning,
                icon: Icons.warning_amber_rounded, color: t.orange),
          ],
        ]),
      );
    });
  }

  Widget _buildLiteRtGroup(BuildContext context) {
    final modes = [
      (
        value: 'auto_fast',
        title: '自动快速',
        subtitle:
            "支持时使用 GPU；GPU 无法加载模型时使用 CPU",
        icon: Icons.auto_awesome_outlined
      ),
      (
        value: 'gpu_fast',
        title: 'GPU 快速',
        subtitle: '始终尝试使用 GPU。速度最快，但在某些设备上可能崩溃',
        icon: Icons.bolt_rounded
      ),
      (
        value: 'cpu_safe',
        title: 'CPU 安全',
        subtitle: '仅 CPU。最稳定，但较慢',
        icon: Icons.shield_outlined
      ),
    ];
    final t = AppTokens.of(context);
    return AppGroup(dividerIndent: 60, children: [
      for (final m in modes)
        AppRow(
          icon: m.icon,
          title: m.title,
          subtitle: m.subtitle,
          selected: controller.liteRtPerformanceMode.value == m.value,
          onTap: () => controller.setLiteRtPerformanceMode(m.value),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Text(
            '适用于 GGUF 和 LiteRT 模型。将在下一次'
            '加载模型时生效。',
            style: t.small),
      ),
    ]);
  }

  Widget _buildModelParametersGroup(BuildContext context) {
    return AppGroup(children: [
      _modelParameterSlider(
        context,
        label: '温度',
        value: controller.temperature.value,
        min: 0.0,
        max: 2.0,
        divisions: 20,
        safeMax: 1.0,
        onChanged: (v) => controller.setTemperature(v),
        warning: '温度过高 = 输出不可预测！',
      ),
      _modelParameterSlider(
        context,
        label: '最大 Token 数',
        value: controller.maxTokens.value.toDouble(),
        min: 64,
        max: 4096,
        divisions: 63,
        safeMax: Get.find<DeviceInfoService>().maxSafeTokens.toDouble(),
        onChanged: (v) => controller.setMaxTokens(v.toInt()),
        displayValue: controller.maxTokens.value.toString(),
        warning: '这个值可能让你的手机崩溃！',
      ),
      (() {
        final inference = Get.find<InferenceService>();
        final savedRuntime = Get.find<HiveService>()
                .getSetting<String>(AppConstants.keyLocalModelRuntime) ??
            '';
        final isLiteRtActive = (inference.isModelLoaded.value &&
                inference.loadedModelRuntime.value == 'litert') ||
            (!inference.isModelLoaded.value &&
                savedRuntime.toLowerCase() == 'litert');
        final maxContext = isLiteRtActive ? 4096.0 : 8192.0;
        final divisions = isLiteRtActive ? 7 : 15;
        final currentValue =
            controller.contextSize.value.toDouble().clamp(512.0, maxContext);

        if (currentValue != controller.contextSize.value.toDouble()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.setContextSize(currentValue.toInt());
          });
        }

        return _modelParameterSlider(
          context,
          label: '上下文长度',
          value: currentValue,
          min: 512,
          max: maxContext,
          divisions: divisions,
          safeMax: Get.find<DeviceInfoService>().maxSafeContextSize.toDouble(),
          onChanged: (v) => controller.setContextSize(v.toInt()),
          displayValue: currentValue.toInt().toString(),
          warning: isLiteRtActive
              ? '上下文上限为 4096，以防 LiteRT 模型出现驱动内存崩溃。'
              : '上下文这么大，会吃光你的内存！',
        );
      })(),
    ]);
  }

  Widget _modelParameterSlider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required String warning,
    String? displayValue,
  }) {
    final t = AppTokens.of(context);
    final isOver = value > safeMax;
    final danger = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final warnColor = isOver ? Color.lerp(t.orange, t.red, danger)! : null;

    return _sliderRow(
      context,
      label: label,
      valueLabel: displayValue ?? value.toStringAsFixed(2),
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      color: warnColor,
      caption: safeMax < max
          ? '推荐最大值：${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}'
          : null,
      onChanged: (v) {
        if (v > safeMax && value <= safeMax) {
          Haptics.heavyImpact();
          showToast('高于推荐值', warning, tone: ToastTone.warning);
        } else if (v > safeMax) {
          Haptics.mediumImpact();
        }
        onChanged(v);
      },
      below: [
        if (isOver)
          AppNotice(warning,
              icon: Icons.warning_amber_rounded, color: warnColor),
      ],
    );
  }

  Widget _buildImageGenerationGroup(BuildContext context) {
    final t = AppTokens.of(context);
    final stepsValue = controller.imageSteps.value.toDouble();
    const safeMax = 8.0;
    final isOver = stepsValue > safeMax;
    final selectedBackend = controller.imageGenBackend.value;
    final gpuBackend = controller.recommendedImageGpuBackend();
    final gpuAvailable = gpuBackend != Backend.cpu;
    final size = controller.imageGenSize.value;
    final guard = controller.imageGenGpuGuardMb.value;

    return AppGroup(children: [
      // Steps
      _sliderRow(
        context,
        label: '步数',
        valueLabel: controller.imageSteps.value.toString(),
        value: stepsValue.clamp(1, 50),
        min: 1,
        max: 50,
        divisions: 49,
        color: isOver ? t.orange : null,
        caption: '推荐：15-20 步',
        onChanged: (v) => controller.setImageSteps(v.toInt()),
        below: [
          if (isOver)
            AppNotice('步数越多质量越好，但速度会慢得多！',
                icon: Icons.warning_amber_rounded, color: t.orange),
        ],
      ),

      // Size
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('图片尺寸', style: t.body)),
            Text(size == 0 ? '自动' : '${size}px',
                style: t.body.copyWith(color: t.muted, fontFeatures: _tabular)),
          ]),
          const SizedBox(height: 12),
          AppChips<int>(
            items: const [
              (0, '自动'),
              (256, '256'),
              (320, '320'),
              (384, '384'),
              (512, '512'),
            ],
            selected: size,
            onSelected: (v) => controller.setImageGenSize(v),
          ),
          const SizedBox(height: 10),
          Text(
              '推荐自动。尺寸越大细节越好，但速度慢得多，内存占用也更多。',
              style: t.small),
          if (size >= 512) ...[
            const SizedBox(height: 10),
            AppNotice(
                '512 细节更多，但速度会慢很多、手机容易发热，且在某些设备上可能失败。',
                icon: Icons.warning_amber_rounded,
                color: t.orange),
          ],
        ]),
      ),

      // GPU safety
      _sliderRow(
        context,
        label: 'GPU 安全',
        valueLabel: guard <= 0 ? '关' : '$guard MB',
        value: guard.toDouble().clamp(0, 4096),
        min: 0,
        max: 4096,
        divisions: 16,
        caption:
            '达到或超过此大小的模型使用 CPU。较小的模型可使用 GPU 实验模式。',
        onChanged: (v) => controller.setImageGenGpuGuardMb(v.toInt()),
        below: [
          if (guard <= 0 || guard >= 2048)
            AppNotice(
                guard <= 0
                    ? 'GPU 安全已关闭。大模型在 GPU 上可能崩溃或卡死。'
                    : '高 GPU 安全等级允许在 GPU 上运行更大的模型，可能导致某些手机崩溃、卡死或过热。',
                icon: Icons.warning_amber_rounded,
                color: t.orange),
        ],
      ),

      // Backend
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('后端', style: t.body),
          const SizedBox(height: 2),
          Text(controller.imageGpuLabel(), style: t.caption),
          const SizedBox(height: 12),
          AppSegmented<bool>(
            items: const [(false, 'CPU'), (true, 'GPU')],
            selected: selectedBackend != Backend.cpu,
            onChanged: (useGpu) {
              if (useGpu == (selectedBackend != Backend.cpu)) return;
              if (useGpu && !gpuAvailable) return;
              controller.setImageBackendMode(useGpu);
            },
          ),
          if (selectedBackend != Backend.cpu) ...[
            const SizedBox(height: 10),
            Text('GPU 模式为实验功能，仅在 GPU 安全大小以下使用。',
                style: t.small.copyWith(color: t.orange)),
          ],
        ]),
      ),
    ]);
  }
}

/// A settings section on its own page. Rebuilds with the controller state.
class _SettingsPage extends StatelessWidget {
  final String title;
  final WidgetBuilder builder;

  /// Rebuild on controller changes. Off for pages that read no observables
  /// (or manage their own Obx), which GetX would otherwise reject.
  final bool reactive;
  const _SettingsPage(
      {required this.title, required this.builder, this.reactive = true});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: title, showBack: true),
      body: reactive ? Obx(() => _list(context)) : _list(context),
    );
  }

  Widget _list(BuildContext context) => ListView(
        padding: kPagePadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [const SizedBox(height: 8), builder(context)],
      );
}
