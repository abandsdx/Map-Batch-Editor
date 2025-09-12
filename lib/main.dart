import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:window_size/window_size.dart';
import 'zip_generator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    setWindowTitle('Floor ZIP Generator');
    setWindowMinSize(const Size(400, 600));
    setWindowMaxSize(Size.infinite);
    setWindowFrame(const Rect.fromLTWH(100, 100, 400, 600));
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Floor ZIP Generator',
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _zipGenerator = FloorZipGenerator();
  final _logScrollController = ScrollController();

  String? zipPath;
  String? outputDir;
  String floorInput = '';
  String log = '';
  bool _isLoading = false;

  @override
  void dispose() {
    _logScrollController.dispose();
    super.dispose();
  }

  void _clearLog() {
    setState(() {
      log = '';
    });
  }

  void appendLog(String message) {
    if (mounted) {
      setState(() {
        log += message + '\n';
      });
      Future.delayed(const Duration(milliseconds: 50), () {
        if (_logScrollController.hasClients) {
          _logScrollController.animateTo(
            _logScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> pickZip() async {
    if (_isLoading) return;
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        zipPath = result.files.single.path;
      });
    }
  }

  Future<void> pickOutputDir() async {
    if (_isLoading) return;
    String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) {
      setState(() {
        outputDir = dir;
      });
    }
  }

  Future<void> generateZips() async {
    if (_isLoading) return;

    setState(() {
      log = '';
      _isLoading = true;
    });

    if (zipPath == null) {
      appendLog('請先選擇來源 ZIP');
      setState(() => _isLoading = false);
      return;
    }
    if (outputDir == null) {
      appendLog('請先選擇輸出資料夾');
      setState(() => _isLoading = false);
      return;
    }

    await _zipGenerator.generateZips(
      zipPath: zipPath!,
      outputDir: outputDir!,
      floorInput: floorInput,
      onLog: appendLog,
    );

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Floor ZIP Generator')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed: _isLoading ? null : pickZip,
                  child: Text(zipPath == null ? '選擇來源 ZIP' : '來源 ZIP: ${p.basename(zipPath!)}'),
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _isLoading ? null : pickOutputDir,
                  child: Text(outputDir == null ? '選擇輸出資料夾' : '輸出資料夾: $outputDir'),
                ),
                const SizedBox(height: 10),
                TextField(
                  enabled: !_isLoading,
                  decoration: const InputDecoration(
                    labelText: '目標樓層 (支援範圍，例如 4,5-8,10)',
                  ),
                  onChanged: (v) => floorInput = v,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _isLoading ? null : generateZips,
                  child: const Text('執行生成'),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('執行日誌', style: Theme.of(context).textTheme.titleMedium),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _isLoading ? null : _clearLog,
                      tooltip: '清除日誌',
                    ),
                  ],
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      controller: _logScrollController,
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(log, style: const TextStyle(fontFamily: 'monospace')),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.5), // ✅ 新版 API
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
