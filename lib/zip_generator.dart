import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;
import 'package:yaml_writer/yaml_writer.dart';

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

    final tasks = <Future>[];
    for (var floor in floors) {
      tasks.add(_buildNewFloorZip(zipPath, floor, outputDir, onLog).catchError((e) {
        onLog('錯誤: 在處理樓層 $floor 時發生錯誤: $e');
      }));
    }

    await Future.wait(tasks);
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

  Future<void> _buildNewFloorZip(
      String templateZip, int targetFloor, String outDir, ValueChanged<String> onLog) async {
    onLog('正在生成樓層 $targetFloor ...');

    // To make this truly parallel and not block the main isolate,
    // this entire operation should be moved to a separate isolate.
    // However, for a start, Future.wait improves concurrent I/O.
    // The synchronous I/O calls within are still a bottleneck.
    // Let's refactor them to be async.

    final baseName = p.basename(templateZip);

    final match = RegExp(r'(\d+)F\.zip$').firstMatch(baseName);
    if (match == null) throw Exception('來源檔名格式錯誤');
    final sourceFloor = int.parse(match.group(1)!);
    final outZip = p.join(
        outDir, baseName.replaceAll('${sourceFloor}F.zip', '${targetFloor}F.zip'));

    final tempDir = await Directory.systemTemp.createTemp('floor_zip_');

    try {
      // 解壓 ZIP
      final bytes = await File(templateZip).readAsBytes();
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

      // 修改 graph.yaml
      for (var fname in ['graph.yaml']) {
        final fpath = p.join(tempDir.path, fname);
        final file = File(fpath);
        if (await file.exists()) {
          var text = await file.readAsString();
          text = text.replaceAllMapped(
              RegExp(r'(\w+_' + sourceFloor.toString() + r'F)'),
              (m) => m.group(1)!.replaceAll('${sourceFloor}F', '${targetFloor}F'));
          await file.writeAsString(text);
        }
      }

      // 修改 map.json
      final mapFile = File(p.join(tempDir.path, 'map.json'));
      if (await mapFile.exists()) {
        var text = await mapFile.readAsString();
        final mapData = Map<String, dynamic>.from(jsonDecode(text));
        if (mapData.containsKey('name')) {
          mapData['name'] = (mapData['name'] as String)
              .replaceAll('${sourceFloor}F', '${targetFloor}F');
        }
        await mapFile.writeAsString(jsonEncode(mapData));
      }

      // 修改 location.yaml
      final locFile = File(p.join(tempDir.path, 'location.yaml'));
      if (await locFile.exists()) {
        final content = await locFile.readAsString();
        final data = loadYaml(content);

        Map newData = {};
        if (data is Map) {
          for (var k in data.keys) {
            if (k == 'loc') {
              newData[k] = data[k];
            } else if (RegExp(r'^[A-Z]+[0-9]{4}$').hasMatch(k) && !k.startsWith('MA')) {
              final prefix = RegExp(r'^([A-Z]+)').firstMatch(k)!.group(1)!;
              final num = k.substring(prefix.length);
              final newKey =
                  '$prefix${targetFloor.toString().padLeft(2, '0')}${num.substring(2)}';
              newData[newKey] = data[k];
            } else {
              newData[k] = data[k];
            }
          }
        }

        final yamlString = YamlWriter().write(newData);
        await locFile.writeAsString(yamlString);
      }

      // 打包 ZIP
      final encoder = ZipFileEncoder();
      encoder.create(outZip);
      await for (final entity in tempDir.list(recursive: true)) {
         final relative = p.relative(entity.path, from: tempDir.path);
         if (entity is File) {
           await encoder.addFile(entity, relative);
         }
      }
      encoder.close();
      onLog('完成: $targetFloor -> $outZip');
    } finally {
      await tempDir.delete(recursive: true);
    }
  }
}
