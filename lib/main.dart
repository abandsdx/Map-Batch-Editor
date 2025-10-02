import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';
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

  String? _extractFloorName(String rawName) {
    if (rawName.isEmpty) return null;
    // This regex looks for patterns like "9F", "F9", "F10", "10F" case-insensitively.
    final match = RegExp(r'(\d+F|F\d+)', caseSensitive: false).firstMatch(rawName);
    return match?.group(0)?.toUpperCase();
  }

  Future<Map<String, dynamic>?> _getConfirmedSourceInfo(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final Set<String> foundNames = {};

      // 1. Parse from filename
      final fileName = p.basename(zipPath);
      final nameFromFile = _extractFloorName(fileName);
      if (nameFromFile != null) {
        foundNames.add(nameFromFile);
      }

      // 2. Parse from map.json
      final mapFile = archive.findFile('map.json');
      if (mapFile != null) {
        final mapData = jsonDecode(utf8.decode(mapFile.content as List<int>));
        final nameFromJsonRaw = mapData['name'] as String?;
        if (nameFromJsonRaw != null) {
          final nameFromJson = _extractFloorName(nameFromJsonRaw);
          if (nameFromJson != null) {
            foundNames.add(nameFromJson);
          }
        }
      }

      // 3. Parse from graph.yml
      final graphFile = archive.findFile('graph.yml');
      if (graphFile != null) {
          final graphContent = utf8.decode(graphFile.content as List<int>);
          final graphData = loadYaml(graphContent);
          if (graphData is Map && graphData.containsKey('name')) {
              final nameFromGraphRaw = graphData['name'] as String?;
              if (nameFromGraphRaw != null) {
                  final nameFromGraph = _extractFloorName(nameFromGraphRaw);
                  if (nameFromGraph != null) {
                      foundNames.add(nameFromGraph);
                  }
              }
          }
      }

      if (foundNames.isEmpty) {
        appendLog('錯誤：在檔名、map.json 或 graph.yml 中都找不到有效的樓層名稱。');
        return null;
      }

      if (foundNames.length == 1) {
        final name = foundNames.first;
        return {'correctFloorName': name, 'namesToReplace': foundNames.toList()};
      }

      // Conflict detected, ask user
      final String? chosenName = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('偵測到多重名稱衝突'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('在不同位置偵測到以下樓層名稱，請選擇一個作為正確的來源：'),
                const SizedBox(height: 16),
                ...foundNames.map((name) => RadioListTile<String>(
                  title: Text(name),
                  value: name,
                  groupValue: null, // We handle state outside
                  onChanged: (value) {
                     Navigator.of(context).pop(value);
                  },
                )).toList(),
              ],
            ),
            actions: <Widget>[
              TextButton(
                child: const Text('取消'),
                onPressed: () => Navigator.of(context).pop(null),
              ),
            ],
          );
        },
      );

      if (chosenName == null) {
        return null; // User cancelled
      }

      return {'correctFloorName': chosenName, 'namesToReplace': foundNames.toList()};

    } on FileSystemException catch (e) {
      appendLog('錯誤：無法讀取檔案。\n檔案路徑: $zipPath\n原因: ${e.message}\n請確認檔案是否存在且未被移動或刪除。');
      return null;
    } catch (e) {
      appendLog('驗證過程中發生未知錯誤: $e');
      return null;
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

    final sourceInfo = await _getConfirmedSourceInfo(zipPath!);
    if (sourceInfo == null) {
      appendLog('操作已取消或驗證失敗。');
      setState(() => _isLoading = false);
      return;
    }

    appendLog('驗證成功。選擇的來源樓層: ${sourceInfo['correctFloorName']}');
    appendLog('將替換以下舊名稱: ${sourceInfo['namesToReplace'].join(', ')}');


    await _zipGenerator.generateZips(
      zipPath: zipPath!,
      outputDir: outputDir!,
      floorInput: floorInput,
      onLog: appendLog,
      sourceInfo: sourceInfo,
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
                        child: SelectableText(log, style: const TextStyle(fontFamily: 'monospace')),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
