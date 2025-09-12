import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;
import 'package:yaml_writer/yaml_writer.dart';

/// A data class to hold parameters for the isolate.
class _IsolateParams {
  final String zipPath;
  final String outputDir;
  final int targetFloor;
  final SendPort sendPort;

  _IsolateParams({
    required this.zipPath,
    required this.outputDir,
    required this.targetFloor,
    required this.sendPort,
  });
}

/// This is the entry point for the isolate.
/// It performs the heavy lifting of unzipping, modifying, and re-zipping.
Future<void> _zipProcessor(_IsolateParams params) async {
  final sendPort = params.sendPort;

  void log(String message) {
    sendPort.send({'type': 'log', 'payload': message});
  }

  try {
    log('正在處理樓層 ${params.targetFloor} ...');

    final baseName = p.basename(params.zipPath);
    final match = RegExp(r'(\d+)F\.zip$').firstMatch(baseName);
    if (match == null) throw Exception('來源檔名格式錯誤');
    final sourceFloor = int.parse(match.group(1)!);
    final outZip = p.join(params.outputDir,
        baseName.replaceAll('${sourceFloor}F.zip', '${params.targetFloor}F.zip'));

    final tempDir = await Directory.systemTemp.createTemp('floor_zip_iso_${params.targetFloor}');

    try {
      // Unzip
      final bytes = await File(params.zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (var file in archive) {
        final filename = p.join(tempDir.path, file.name);
        if (file.isFile) {
          final outFile = File(filename);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filename).create(recursive: true);
        }
      }

      // Modify graph.yaml
      final graphFile = File(p.join(tempDir.path, 'graph.yaml'));
      if (await graphFile.exists()) {
        var text = await graphFile.readAsString();
        text = text.replaceAllMapped(
            RegExp(r'(\w+_' + sourceFloor.toString() + r'F)'),
            (m) => m.group(1)!.replaceAll('${sourceFloor}F', '${params.targetFloor}F'));
        await graphFile.writeAsString(text);
      }

      // Modify map.json
      final mapFile = File(p.join(tempDir.path, 'map.json'));
      if (await mapFile.exists()) {
        var text = await mapFile.readAsString();
        final mapData = Map<String, dynamic>.from(jsonDecode(text));
        if (mapData.containsKey('name')) {
          mapData['name'] = (mapData['name'] as String)
              .replaceAll('${sourceFloor}F', '${params.targetFloor}F');
        }
        await mapFile.writeAsString(jsonEncode(mapData));
      }

      // Modify location.yaml
      final locFile = File(p.join(tempDir.path, 'location.yaml'));
      if (await locFile.exists()) {
        final content = await locFile.readAsString();
        final data = loadYaml(content);
        Map<String, dynamic> newData = {};
        if (data is Map) {
          for (var entry in data.entries) {
            final key = entry.key.toString();

            if (key == 'loc' && entry.value is Map) {
              // Unnest the 'loc' map and transform its keys
              final locMap = entry.value as Map;
              for (var locEntry in locMap.entries) {
                final locKey = locEntry.key.toString();

                if (RegExp(r'^[A-Z]+[0-9]{4}$').hasMatch(locKey) && !locKey.startsWith('MA')) {
                  final prefix = RegExp(r'^([A-Z]+)').firstMatch(locKey)!.group(1)!;
                  final numStr = locKey.substring(prefix.length);
                  final newKey =
                      '$prefix${params.targetFloor.toString().padLeft(2, '0')}${numStr.substring(2)}';
                  newData[newKey] = locEntry.value;
                } else {
                  newData[locKey] = locEntry.value;
                }
              }
            } else {
              // Preserve other top-level keys
              newData[key] = entry.value;
            }
          }
        }
        await locFile.writeAsString(YamlWriter().write(newData));
      }

      // Re-zip
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
    // Signal completion
    sendPort.send({'type': 'done'});
  } catch (e, s) {
    // Signal error
    sendPort.send({
      'type': 'error',
      'payload': '處理樓層 ${params.targetFloor} 失敗: $e\n$s'
    });
  }
}


class FloorZipGenerator {
  Future<void> generateZips({
    required String zipPath,
    required String outputDir,
    required String floorInput,
    required ValueChanged<String> onLog,
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
