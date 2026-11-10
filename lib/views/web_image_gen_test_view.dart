import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/local_image_service.dart';

/// Minimal test screen for WebGPU image generation.
/// Open this route to test CyberRealistic/DreamShaper in the browser.
class WebImageGenTestView extends StatefulWidget {
  const WebImageGenTestView({super.key});

  @override
  State<WebImageGenTestView> createState() => _WebImageGenTestViewState();
}

class _WebImageGenTestViewState extends State<WebImageGenTestView> {
  final _promptCtrl = TextEditingController(
    text: 'a portrait of a cyberpunk woman, neon lights, detailed, 8k',
  );
  final _localImage = Get.find<LocalImageService>();
  Uint8List? _imageBytes;
  String _status = '点击「加载模型」以初始化 WebGPU 引擎。';

  @override
  void initState() {
    super.initState();
    // Auto-load model on open
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadModel());
  }

  Future<void> _loadModel() async {
    setState(() => _status = '正在加载模型…');
    final result = await _localImage.loadModel('');
    setState(() => _status = result);
  }

  Future<void> _generate() async {
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _imageBytes = null;
      _status = '正在生成…';
    });

    final bytes = await _localImage.generateImage(
      prompt: prompt,
      onProgress: (step, total) {
        setState(() => _status = '第 $step 步 / 共 $total 步');
      },
    );

    setState(() {
      _imageBytes = bytes;
      _status = bytes != null
          ? 'Done! ${bytes.length} bytes'
          : '生成失败。请查看浏览器控制台。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: Text('WebGPU 图片生成测试',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        backgroundColor: isDark ? Colors.black : Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('模型', style: GoogleFonts.inter(fontSize: 12, color: Colors.grey)),
            Text('CyberRealistic-LCM (WebGPU → Metal on Apple)',
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w500)),
            const SizedBox(height: 16),
            TextField(
              controller: _promptCtrl,
              decoration: InputDecoration(
                hintText: '输入提示词…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _localImage.isModelLoaded.value ? null : _loadModel,
                  child: const Text('加载模型'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _localImage.isModelLoaded.value ? _generate : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0A84FF),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('生成'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: GoogleFonts.inter(fontSize: 13, color: Colors.grey)),
            if (_localImage.isGenerating.value)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 20),
            if (_imageBytes != null)
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(_imageBytes!, fit: BoxFit.contain),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }
}
