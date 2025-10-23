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
    log('甇???璅惜 ${params.targetFloor} ...');

    final outputBaseName = params.sourceInfo['outputBaseName'] as String;
    final correctFloorName = params.sourceInfo['correctFloorName'] as String;

    final newFloorIdentifier = '${params.targetFloor}F';
    final newFullName = '$outputBaseName$newFloorIdentifier';

    final outZip = p.join(params.outputDir, '$newFullName.zip');

    final tempDir = await Directory.systemTemp
        .createTemp('floor_zip_iso_${params.targetFloor}');

    try {
      // 閫??蝮桀?憪?ZIP
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

      // ???芯耨??graph.yaml ??name 甈?
      final graphFile = File(p.join(tempDir.path, 'graph.yaml'));
      if (await graphFile.exists()) {
        String content = await graphFile.readAsString();

        final nameRegex = RegExp(r'^name:\s*(.*)$', multiLine: true);
        if (nameRegex.hasMatch(content)) {
          content = content.replaceFirst(nameRegex, 'name: $newFullName');
        } else {
          content = 'name: $newFullName\n$content';
        }

        await graphFile.writeAsString(content);
      }

      // 靽格 map.json ??name 甈?
      final mapFile = File(p.join(tempDir.path, 'map.json'));
      if (await mapFile.exists()) {
        var text = await mapFile.readAsString();
        final mapData = Map<String, dynamic>.from(jsonDecode(text));
        if (mapData.containsKey('name')) {
          mapData['name'] = newFullName;
        }
        await mapFile.writeAsString(jsonEncode(mapData));
      }

      // 靽格 location.yaml嚗 R / WL / XL 璅惜頧?嚗?
      // 靽格 location.yaml嚗? R / WL 璅惜?孵?嚗L 撌脣??剁?
      final locFile = File(p.join(tempDir.path, 'location.yaml'));
      if (await locFile.exists()) {
        // 閫?? YAML
        final content = await locFile.readAsString();
        final data = _convertYamlNode(loadYaml(content));
        final newData = <String, dynamic>{};
        final locData = <String, dynamic>{};

        if (data is Map<String, dynamic>) {
          final Map<String, dynamic> sourceMap =
              data['loc'] is Map<String, dynamic> ? data['loc'] : data;

          // 1) ?? UI 閬??韌嚗??嚗?
          final List<dynamic>? override = params.sourceInfo['overridePrefixes'] as List<dynamic>?;
          Set<String> renamePrefixes = override?.map((e) => e.toString()).toSet() ?? {};

          if (renamePrefixes.isEmpty) {
            // 2) ???菜葫?舀???韌嚗?摮?><?拐??? 銝雿蝑靘?璅惜嚗???EV/LL/MA
            final floorDigits = RegExp(r'(\d+)').firstMatch(correctFloorName)?.group(1);
            final baselineFloor2 = floorDigits == null
                ? null
                : int.tryParse(floorDigits)?.toString().padLeft(2, '0');
            
            if (baselineFloor2 != null) {
              final captureRe = RegExp(r'^([A-Za-z]+)(\d{2})(.*)$');
              for (final k in sourceMap.keys.map((e) => e.toString())) {
                final m = captureRe.firstMatch(k);
                if (m != null) {
                  final prefix = m.group(1)!;
                  final n2 = m.group(2)!;
                  if (n2 == baselineFloor2 ) {
                    renamePrefixes.add(prefix);
                  }
                }
              }
            }
            if (renamePrefixes.isEmpty) {
              renamePrefixes.addAll({'R', 'WL'});
            }
          }
          log('?孵??韌: ${renamePrefixes.join(', ')}');
          final renameRe = RegExp('^(${renamePrefixes.join('|')})(\\d{2})(.*)');

          for (final entry in sourceMap.entries) {
            final key = entry.key.toString();
            final value = entry.value;

            if (key.trim() == 'loc' || value == null) continue;
            // ??R / WL ?嚗雿璅惜蝣潭??

            // ? R / WL / XL ?嚗???拍Ⅳ璅惜?詨?
            final km = renameRe.firstMatch(key);
            if (km != null) {
              final prefix = km.group(1)!;
              final suffix = km.group(3)!;
              final newKey = '$prefix${params.targetFloor.toString().padLeft(2, '0')}$suffix';
              locData[newKey] = value;
            } else {
              // ?嗡? key 銝?嚗?憒?MA05?A06嚗?
              locData[key] = value;
            }
          }
        }

        // 銝??箏?璅⊥嚗??脰?璅惜?孵?

        newData['loc'] = locData;
        await locFile.writeAsString(_writeYaml(newData));
      }


      // ?憯葬? ZIP
      final encoder = ZipFileEncoder();
      encoder.create(outZip);
      await for (final entity in tempDir.list(recursive: true)) {
        final relative = p.relative(entity.path, from: tempDir.path);
        if (entity is File) {
          await encoder.addFile(entity, relative);
        }
      }
      encoder.close();

      log('摰?: ${params.targetFloor} -> $outZip');
    } finally {
      await tempDir.delete(recursive: true);
    }

    sendPort.send({'type': 'done'});
  } catch (e, s) {
    sendPort.send({
      'type': 'error',
      'payload': '??璅惜 ${params.targetFloor} 憭望?: $e\n$s'
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

/// ??loc ?憛?憭葬??銝??loc: 敺憭?蝛箸
String _writeYaml(Map<String, dynamic> map, {int indentLevel = 0}) {
  final buffer = StringBuffer();
  final indent = '  ' * indentLevel;

  for (var entry in map.entries) {
    final key = entry.key;
    final value = entry.value;

    // ?? ?靽格嚗宏?文????寧?蝛箇
    buffer.write('$indent$key:');

    if (value is Map<String, dynamic>) {
      if (value.isEmpty) {
        buffer.writeln(' {}');
      } else {
        buffer.writeln();
        final nextIndent = (key == 'loc') ? indentLevel : indentLevel + 1;
        buffer.write(_writeYaml(value, indentLevel: nextIndent));
      }
    } else if (value is List) {
      final listContent = value.map((item) => item.toString()).join(', ');
      buffer.writeln(' [$listContent]');
    } else {
      // ?ㄐ??銝?征?賜Ⅱ靽撘迤蝣?
      buffer.writeln(' $value');
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
      onLog('隢撓?交???撅歹?靘?: 4,5-6,8');
      return;
    }

    onLog('撠???撅? ${floors.join(',')}');

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
          ),
        );
      } catch (e) {
        onLog("?⊥?撱箇? Isolate 靘???撅?$floor: $e");
        completer.complete();
      }
    }

    await Future.wait(completers);
    onLog('All tasks completed.');
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

