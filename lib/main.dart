import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
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
    return const MaterialApp(
      title: 'Floor ZIP Generator',
      home: HomePage(),
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
  String _outputBaseName = '';
  final _baseNameController = TextEditingController();
  String log = '';
  bool _isLoading = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  void dispose() {
    _logScrollController.dispose();
    _baseNameController.dispose();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() {
        final build = info.buildNumber.trim();
        _appVersion = build.isNotEmpty ? '${info.version}+$build' : info.version;
      });
    } catch (_) {}
  }

  void _clearLog() {
    setState(() => log = '');
  }

  void appendLog(String message) {
    if (!mounted) return;
    setState(() => log += '$message\n');
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

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Floor ZIP Generator',
      applicationVersion: _appVersion.isEmpty ? 'version unknown' : _appVersion,
      children: const [
        Text('功能:'),
        SizedBox(height: 4),
        Text('• 批次產生多樓層 ZIP'),
        Text('• 自動更新 map.json 與 graph.yaml 的 name'),
        Text('• 由 location.yaml 動態偵測前綴，於 UI 勾選後改名'),
        ],
    );
  }

  Future<void> pickZip() async {
    if (_isLoading) return;
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (result != null && result.files.single.path != null) {
      final newPath = result.files.single.path!;
      final baseName = p.basename(newPath);
      final match = RegExp(r'^(.*?)(_?)(F?\d+F?)(.*\.zip)$', caseSensitive: false).firstMatch(baseName);
      setState(() {
        zipPath = newPath;
        if (match != null) {
          _outputBaseName = '${match.group(1)}${match.group(2)}';
          _baseNameController.text = _outputBaseName;
        } else {
          _outputBaseName = '';
          _baseNameController.text = '';
        }
      });
    }
  }

  Future<void> pickOutputDir() async {
    if (_isLoading) return;
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) {
      setState(() => outputDir = dir);
    }
  }

  Map<String, String>? _extractNameParts(String rawName) {
    if (rawName.isEmpty) return null;
    final clean = rawName.replaceAll('.zip', '');
    final m = RegExp(r'(F?\d+F?)$', caseSensitive: false).firstMatch(clean);
    if (m != null) {
      return {'base': clean.substring(0, m.start), 'floor': m.group(0)!.toUpperCase()};
    }
    return null;
  }

  Future<String?> _detectSourceFloorFromZip(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      // 1. from filename
      final fn = p.basename(zipPath);
      final p1 = _extractNameParts(fn);
      if (p1 != null && p1['floor']!.isNotEmpty) return p1['floor'];
      // 2. from map.json
      final mapFile = archive.findFile('map.json');
      if (mapFile != null) {
        final mapData = jsonDecode(utf8.decode(mapFile.content as List<int>));
        final n = mapData['name'] as String?;
        final p2 = n == null ? null : _extractNameParts(n);
        if (p2 != null && p2['floor']!.isNotEmpty) return p2['floor'];
      }
      // 3. from graph.yml
      final graphFile = archive.findFile('graph.yml') ?? archive.findFile('graph.yaml');
      if (graphFile != null) {
        final yaml = utf8.decode(graphFile.content as List<int>);
        final data = loadYaml(yaml);
        if (data is Map && data.containsKey('name')) {
          final n = data['name'] as String?;
          final p3 = n == null ? null : _extractNameParts(n);
          if (p3 != null && p3['floor']!.isNotEmpty) return p3['floor'];
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Set<String>> _detectRenamePrefixesFromZip(String zipPath, String chosenFloor) async {
    final Set<String> prefixes = {};
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final locFile = archive.findFile('location.yaml') ?? archive.findFile('location.yml');
      if (locFile == null) return prefixes;
      final content = utf8.decode(locFile.content as List<int>);
      final raw = loadYaml(content);
      Map<String, dynamic>? map;
      if (raw is YamlMap) {
        map = Map<String, dynamic>.fromEntries(raw.entries.map((e) => MapEntry(e.key.toString(), e.value)));
      }
      if (map == null) return prefixes;
      final src = (map['loc'] is Map) ? Map<String, dynamic>.from(map['loc']) : map;
      final digits = RegExp(r'(\d+)').firstMatch(chosenFloor)?.group(1);
      if (digits == null) return prefixes;
      final floor2 = int.tryParse(digits)?.toString().padLeft(2, '0');
      if (floor2 == null) return prefixes;
      // 固定不改名前綴（含 XL）
      
      final cap = RegExp(r'^([A-Za-z]+)(\d{2})(.*)$');
      for (final k in src.keys.map((e) => e.toString())) {
        final m = cap.firstMatch(k);
        if (m != null) {
          final prefix = m.group(1)!;
          final n2 = m.group(2)!;
          if (n2 == floor2 ) prefixes.add(prefix);
        }
      }

      // 若未偵測到任何（來源樓層不吻合的情況），退回「忽略樓層碼」的抓取
      if (prefixes.isEmpty) {
        for (final k in src.keys.map((e) => e.toString())) {
          final m = cap.firstMatch(k);
          if (m != null) {
            final prefix = m.group(1)!;
            prefixes.add(prefix);
          }
        }
      }
    } catch (_) {}
    return prefixes;
  }

  Future<void> generateZips() async {
    if (_isLoading) return;
    setState(() { log = ''; _isLoading = true; });
    if (zipPath == null) { appendLog('請選擇來源 ZIP'); setState(() => _isLoading = false); return; }
    if (outputDir == null) { appendLog('請選擇輸出資料夾'); setState(() => _isLoading = false); return; }

    // detect source floor
    final srcFloor = await _detectSourceFloorFromZip(zipPath!);
    if (srcFloor == null) { appendLog('無法從 ZIP 取得來源樓層 (例如 16F)'); setState(() => _isLoading = false); return; }

    // build namesToReplace (not used but kept for compatibility)
    final namesToReplace = <String>{srcFloor};

    // detect prefixes and let user choose
    if (!mounted) return; // guard context
    final autoPrefixes = await _detectRenamePrefixesFromZip(zipPath!, srcFloor);
    if (!mounted) return;
    final Set<String> initial = {...(autoPrefixes.isNotEmpty ? autoPrefixes : {'R','WL'})};
    Set<String>? chosen;
    if (initial.isNotEmpty) {
      chosen = await showDialog<Set<String>>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          final Map<String, bool> state = { for (final p in initial) p: true };
          return StatefulBuilder(
            builder: (context, setState) {
              return AlertDialog(
                title: const Text('選擇要改名的前綴'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('自動偵測到以下前綴，請勾選要改名的：'),
                      const SizedBox(height: 8),
                      ...state.keys.map((p) => CheckboxListTile(
                            title: Text(p),
                            value: state[p]!,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setState(() => state[p] = v ?? false),
                          )),
                    ],
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('取消')),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(state.entries.where((e) => e.value).map((e) => e.key).toSet()),
                    child: const Text('確定'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (chosen == null) { appendLog('已取消'); setState(() => _isLoading = false); return; }
      appendLog('將改名前綴: ${chosen.join(', ')}');
    }

    final sourceInfo = <String, dynamic>{
      'outputBaseName': _outputBaseName,
      'correctFloorName': srcFloor,
      'correctBaseName': '',
      'namesToReplace': namesToReplace.toList(),
      if (chosen != null) 'overridePrefixes': chosen.toList(),
    };

    await _zipGenerator.generateZips(
      zipPath: zipPath!,
      outputDir: outputDir!,
      floorInput: floorInput,
      onLog: appendLog,
      sourceInfo: sourceInfo,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Floor ZIP Generator'),
        actions: [
          IconButton(tooltip: '關於', icon: const Icon(Icons.info_outline), onPressed: _showAbout),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
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
                  controller: _baseNameController,
                  enabled: !_isLoading,
                  decoration: const InputDecoration(labelText: '輸出基底名稱 (例: NUWA_TP_Sheraton_)'),
                  onChanged: (v) => _outputBaseName = v,
                ),
                const SizedBox(height: 10),
                TextField(
                  enabled: !_isLoading,
                  decoration: const InputDecoration(labelText: '目標樓層 (例如: 4,5-8,10)'),
                  onChanged: (v) => floorInput = v,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _isLoading ? null : generateZips,
                  child: const Text('開始產生'),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('執行紀錄', style: Theme.of(context).textTheme.titleMedium),
                    IconButton(onPressed: _isLoading ? null : _clearLog, icon: const Icon(Icons.clear))
                  ],
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: SingleChildScrollView(
                      controller: _logScrollController,
                      child: Text(log),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



