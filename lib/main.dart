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

  @override
  void dispose() {
    _logScrollController.dispose();
    _baseNameController.dispose();
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
        log += '$message\n';
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
    String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) {
      setState(() {
        outputDir = dir;
      });
    }
  }

  Map<String, String>? _extractNameParts(String rawName) {
    if (rawName.isEmpty) return null;
    final cleanName = rawName.replaceAll('.zip', '');
    // Finds a floor identifier like '9F' or 'F10' at the end of the string.
    final match = RegExp(r'(F?\d+F?)$', caseSensitive: false).firstMatch(cleanName);
    if (match != null) {
      final floor = match.group(0)!.toUpperCase();
      final base = cleanName.substring(0, match.start);
      return {'base': base, 'floor': floor};
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getConfirmedSourceInfo(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final Set<String> foundBases = {};
      final Set<String> foundFloors = {};

      void addParts(Map<String, String>? parts) {
        if (parts != null) {
          // Only add non-empty base names. An empty base is valid (e.g. for "9F").
          foundBases.add(parts['base']!);
          if (parts['floor']!.isNotEmpty) foundFloors.add(parts['floor']!);
        }
      }

      // 1. From filename
      addParts(_extractNameParts(p.basename(zipPath)));

      // 2. From map.json
      final mapFile = archive.findFile('map.json');
      if (mapFile != null) {
        final mapData = jsonDecode(utf8.decode(mapFile.content as List<int>));
        final nameFromJsonRaw = mapData['name'] as String?;
        if (nameFromJsonRaw != null) {
          addParts(_extractNameParts(nameFromJsonRaw));
        }
      }

      // 3. From graph.yml
      final graphFile = archive.findFile('graph.yml');
      if (graphFile != null) {
          final graphContent = utf8.decode(graphFile.content as List<int>);
          final graphData = loadYaml(graphContent);
          if (graphData is Map && graphData.containsKey('name')) {
              final nameFromGraphRaw = graphData['name'] as String?;
              if (nameFromGraphRaw != null) {
                  addParts(_extractNameParts(nameFromGraphRaw));
              }
          }
      }

      if (foundFloors.isEmpty) {
        appendLog('錯誤：在任何來源中都找不到有效的樓層標識 (例如 9F, F10)。');
        return null;
      }

      // We will show a dialog in the next step. For now, this step's goal is parsing.
      // The lists of found names will be used to build the dialog.
      return {
        'foundBases': foundBases,
        'foundFloors': foundFloors,
      };

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
    if (_outputBaseName.isEmpty && !RegExp(r'^\d+$').hasMatch(floorInput)) {
        appendLog('警告：未指定輸出基本名稱，將只使用樓層號碼作為檔名。');
    }


    final validationResult = await _getConfirmedSourceInfo(zipPath!);
    if (validationResult == null) {
      appendLog('操作已取消或驗證失敗。');
      setState(() => _isLoading = false);
      return;
    }

    final foundBases = validationResult['foundBases'] as Set<String>;
    final foundFloors = validationResult['foundFloors'] as Set<String>;

    String chosenBase = foundBases.isNotEmpty ? foundBases.first : '';
    String chosenFloor = foundFloors.first;

    if (foundBases.length > 1 || foundFloors.length > 1) {
      final Map<String, String>? choices = await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            String? selectedBase = chosenBase;
            String? selectedFloor = chosenFloor;
            return StatefulBuilder(builder: (context, setDialogState) {
              return AlertDialog(
                title: const Text('偵測到名稱衝突'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('請選擇一個正確的來源基本名稱：'),
                      ...foundBases.map((b) => RadioListTile<String>(
                            title: Text(b.isEmpty ? '(無基本名稱)' : b),
                            value: b,
                            groupValue: selectedBase,
                            onChanged: (v) => setDialogState(() => selectedBase = v),
                          )),
                      const SizedBox(height: 16),
                      const Text('請選擇一個正確的來源樓層：'),
                      ...foundFloors.map((f) => RadioListTile<String>(
                            title: Text(f),
                            value: f,
                            groupValue: selectedFloor,
                            onChanged: (v) => setDialogState(() => selectedFloor = v),
                          )),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.of(context)
                          .pop({'base': selectedBase!, 'floor': selectedFloor!}),
                      child: const Text('確認')),
                ],
              );
            });
          });
      if (choices == null) {
        appendLog('操作已取消。');
        setState(() => _isLoading = false);
        return;
      }
      chosenBase = choices['base']!;
      chosenFloor = choices['floor']!;
    }

    final Set<String> namesToReplace = {};
    for (final b in foundBases) {
      for (final f in foundFloors) {
        namesToReplace.add('$b$f');
      }
    }
    namesToReplace.addAll(foundFloors);

    final sourceInfo = {
      'outputBaseName': _outputBaseName,
      'correctFloorName': chosenFloor,
      'correctBaseName': chosenBase,
      'namesToReplace': namesToReplace.toList(),
    };

    appendLog('驗證成功。選擇的來源: $chosenBase$chosenFloor');
    appendLog('將替換以下舊名稱: ${namesToReplace.join(', ')}');
    appendLog('指定的輸出基本名稱: $_outputBaseName');

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
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed: _isLoading ? null : pickZip,
                  child: Text(zipPath == null ? '選擇來源 ZIP' : '來源 ZIP: ${p.basename(zipPath!)}'),
                ),
                const SizedBox(height: 10.0),
                ElevatedButton(
                  onPressed: _isLoading ? null : pickOutputDir,
                  child: Text(outputDir == null ? '選擇輸出資料夾' : '輸出資料夾: $outputDir'),
                ),
                const SizedBox(height: 10.0),
                TextField(
                  controller: _baseNameController,
                  enabled: !_isLoading,
                  decoration: const InputDecoration(
                    labelText: '輸出基本名稱 (例如 NUWA_TP_Sheraton_)',
                  ),
                  onChanged: (v) => _outputBaseName = v,
                ),
                const SizedBox(height: 10.0),
                TextField(
                  enabled: !_isLoading,
                  decoration: const InputDecoration(
                    labelText: '目標樓層 (支援範圍，例如 4,5-8,10)',
                  ),
                  onChanged: (v) => floorInput = v,
                ),
                const SizedBox(height: 20.0),
                ElevatedButton(
                  onPressed: _isLoading ? null : generateZips,
                  child: const Text('執行生成'),
                ),
                const SizedBox(height: 20.0),
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
              color: Colors.black.withAlpha(128),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
