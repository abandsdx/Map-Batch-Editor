import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:async';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;

class _IsolateParams {
  final String zipPath;
  final String outputDir;
  final int targetFloor;
  final SendPort sendPort;
  final Map<String, dynamic> sourceInfo;

  _IsolateParams({
    required this.zipPath,
    required this.outputDir,
    required this.targetFloor,
    required this.sendPort,
    required this.sourceInfo,
  });
}

Future<void> _zipProcessor(_IsolateParams params) async {
  final sendPort = params.sendPort;

  void log(String message) {
    sendPort.send({'type': 'log', 'payload': message});
  }

  try {
    log('正在處理樓層 ${params.targetFloor} ...');

    final outputBaseName = params.sourceInfo['outputBaseName'] as String;
    final namesToReplace =
        (params.sourceInfo['namesToReplace'] as List<dynamic>).cast<String>();
    final correctFloorName = params.sourceInfo['correctFloorName'] as String;

    final newFloorIdentifier = '${params.targetFloor}F';
    final newFullName = '$outputBaseName$newFloorIdentifier';
    final newFloorNumStr = params.targetFloor.toString().padLeft(2, '0');

    final outZip = p.join(params.outputDir, '$newFullName.zip');

    final tempDir = await Directory.systemTemp
        .createTemp('floor_zip_iso_${params.targetFloor}');

    try {
      final bytes = await File(params.zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (var file in archive) {
        final filename = p.join(tempDir.path, file.name);
        if (file.isFile) {
          await File(filename).create(recursive: true);
          await File(filename).writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filename).create(recursive: true);
        }
      }

      // Modify graph.yaml
      final graphFile = File(p.join(tempDir.path, 'graph.yaml'));
      if (await graphFile.exists()) {
        final rawContent = await graphFile.readAsString();
        final data = _convertYamlNode(loadYaml(rawContent));

        if (data is Map<String, dynamic>) {
          // Update root name
          if (data.containsKey('name')) {
            data['name'] = newFullName;
          }

          // Update levels key by finding a match in namesToReplace
          if (data['levels'] is Map) {
            final levelsMap = data['levels'] as Map<String, dynamic>;
            String? keyToReplace;
            // Find the key that needs to be replaced
            for (final key in levelsMap.keys) {
              if (namesToReplace.contains(key)) {
                keyToReplace = key;
                break;
              }
            }

            if (keyToReplace != null) {
              // Re-insert the data with the new key
              final levelData = levelsMap[keyToReplace];
              levelsMap.remove(keyToReplace);
              levelsMap[newFullName] = levelData;
            }
          }
          await graphFile.writeAsString(_writeYaml(data));
        }
      }

      // Modify map.json
      final mapFile = File(p.join(tempDir.path, 'map.json'));
      if (await mapFile.exists()) {
        var text = await mapFile.readAsString();
        final mapData = Map<String, dynamic>.from(jsonDecode(text));
        if (mapData.containsKey('name')) {
          mapData['name'] = newFullName;
        }
        await mapFile.writeAsString(jsonEncode(mapData));
      }

      // Modify location.yaml
      final locFile = File(p.join(tempDir.path, 'location.yaml'));
      if (await locFile.exists()) {
        // 1. Get the single, confirmed source floor number
        final sourceFloorNumMatch = RegExp(r'\d+').firstMatch(correctFloorName);
        if (sourceFloorNumMatch == null) {
          throw Exception("無法從 '$correctFloorName' 中提取來源樓層號碼");
        }
        final sourceFloorNum = int.parse(sourceFloorNumMatch.group(0)!);

        // 2. Parse the file and data
        final content = await locFile.readAsString();
        final data = _convertYamlNode(loadYaml(content));
        final newData = <String, dynamic>{};
        final locData = <String, dynamic>{};

        if (data is Map<String, dynamic>) {
          final Map<String, dynamic> sourceMap =
              data['loc'] is Map<String, dynamic> ? data['loc'] : data;

          for (final entry in sourceMap.entries) {
            final key = entry.key;
            final value = entry.value;

            // 3. Parse each key and compare floor numbers
            final keyMatch = RegExp(r'^R(\d+)(.*)$').firstMatch(key);
            if (keyMatch != null) {
              final keyFloorNum = int.parse(keyMatch.group(1)!);
              final roomPart = keyMatch.group(2)!;

              // 4. If floors match, rebuild key. Otherwise, keep original.
              if (keyFloorNum == sourceFloorNum) {
                final newKey = 'R$newFloorNumStr$roomPart';
                locData[newKey] = value;
              } else {
                locData[key] = value;
              }
            } else {
              // Not a room key (e.g. 'loc' itself), keep original
              locData[key] = value;
            }
          }
        }
        newData['loc'] = locData;
        await locFile.writeAsString(_writeYaml(newData));
      }

      final encoder = ZipFileEncoder();
      encoder.create(outZip);
      await for (final entity in tempDir.list(recursive: true)) {
        final relative = p.relative(entity.path, from: tempDir.path);
        if (entity is File) {
          await encoder.addFile(entity, relative);
        }
      }
      encoder.close();
      log('完成: ${params.targetFloor} -> $outZip');
    } finally {
      await tempDir.delete(recursive: true);
    }
    sendPort.send({'type': 'done'});
  } catch (e, s) {
    sendPort.send({
      'type': 'error',
      'payload': '處理樓層 ${params.targetFloor} 失敗: $e\n$s'
    });
  }
}

// Converts Yaml types to standard Dart types (Map, List).
dynamic _convertYamlNode(dynamic node) {
  if (node is YamlMap) {
    return Map<String, dynamic>.fromEntries(
      node.entries.map(
        (e) => MapEntry(e.key.toString().trim(), _convertYamlNode(e.value)),
      ),
    );
  }
  if (node is YamlList) {
    return List<dynamic>.from(node.map((e) => _convertYamlNode(e)));
  }
  return node;
}

/// ✅ 修正 loc: 區塊不多縮排
String _writeYaml(Map<String, dynamic> map, {int indentLevel = 0}) {
  final buffer = StringBuffer();
  final indent = '  ' * indentLevel;

  for (var entry in map.entries) {
    final key = entry.key;
    final value = entry.value;

    buffer.write('$indent$key: ');

    if (value is Map<String, dynamic>) {
      if (value.isEmpty) {
        buffer.writeln('{}');
      } else {
        buffer.writeln();
        final nextIndent = (key == 'loc') ? indentLevel : indentLevel + 1;
        buffer.write(_writeYaml(value, indentLevel: nextIndent));
      }
    } else if (value is List) {
      final listContent = value.map((item) => item.toString()).join(', ');
      buffer.writeln('[$listContent]');
    } else {
      buffer.writeln('$value');
    }
  }
  return buffer.toString();
}

class FloorZipGenerator {
  Future<void> generateZips({
    required String zipPath,
    required String outputDir,
    required String floorInput,
    required ValueChanged<String> onLog,
    required Map<String, dynamic> sourceInfo,
  }) async {
    final floors = _parseFloorInput(floorInput);
    if (floors.isEmpty) {
      onLog('請輸入有效樓層，例如: 4,5-6,8');
      return;
    }

    onLog('將生成樓層: ${floors.join(',')}');

    final completers = <Future>[];
    for (var floor in floors) {
      final completer = Completer<void>();
      completers.add(completer.future);

      final receivePort = ReceivePort();
      receivePort.listen((message) {
        if (message is Map) {
          switch (message['type']) {
            case 'log':
              onLog(message['payload']);
              break;
            case 'error':
              onLog(message['payload']);
              completer.complete();
              receivePort.close();
              break;
            case 'done':
              completer.complete();
              receivePort.close();
              break;
          }
        }
      });

      try {
        await Isolate.spawn(
            _zipProcessor,
            _IsolateParams(
              zipPath: zipPath,
              outputDir: outputDir,
              targetFloor: floor,
              sendPort: receivePort.sendPort,
              sourceInfo: sourceInfo,
            ));
      } catch (e) {
        onLog("無法建立 Isolate 來處理樓層 $floor: $e");
        completer.complete();
      }
    }

    await Future.wait(completers);
    onLog('所有任務已完成。');
  }

  List<int> _parseFloorInput(String input) {
    final floors = <int>{};
    final parts = input.split(',');
    for (var part in parts) {
      part = part.trim();
      if (part.contains('-')) {
        final range = part.split('-');
        if (range.length == 2) {
          final start = int.tryParse(range[0].trim());
          final end = int.tryParse(range[1].trim());
          if (start != null && end != null && start <= end) {
            floors.addAll([for (var i = start; i <= end; i++) i]);
          }
        }
      } else {
        final num = int.tryParse(part);
        if (num != null) floors.add(num);
      }
    }
    final sorted = floors.toList()..sort();
    return sorted;
  }
}
