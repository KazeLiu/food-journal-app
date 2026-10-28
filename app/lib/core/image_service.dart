import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../records/record_repository.dart';
import 'data.dart';

class ImageService {
  final RecordRepository records;
  final ImagePicker picker = ImagePicker();
  bool recoveredChatImages = false;
  String? recoveryNotice;
  late final Directory root;
  ImageService(this.records);

  Future<void> initialize() async {
    root = Directory(p.join(
        (await getApplicationSupportDirectory()).path, 'pending-images'));
    await root.create(recursive: true);
    await cleanup(orphanDrafts: true);
    final libraryCapture = await records.db.query('app_settings',
        where: 'key=?', whereArgs: ['library_photo_capture']);
    final response = await picker.retrieveLostData();
    await records.db.delete('app_settings',
        where: 'key=?', whereArgs: ['library_photo_capture']);
    if (libraryCapture.isNotEmpty) {
      final saved = await records.db.query('app_settings',
          where: 'key=?', whereArgs: ['library_editor_draft']);
      final draft = saved.isEmpty
          ? <String, dynamic>{
              'values': <String, dynamic>{},
              'photos': <String>[]
            }
          : jsonMap(saved.single['value_json'] as String);
      final ids = List<String>.from(draft['photos'] as List);
      for (final file in response.files ??
          <XFile>[if (response.file != null) response.file!]) {
        if (ids.length < 3) {
          ids.add((await prepare(file))['id'] as String);
        } else {
          await _removePickerCopy(file);
        }
      }
      await records.db.insert(
          'app_settings',
          {
            'key': 'library_editor_draft',
            'value_json': jsonEncode({
              ...draft,
              'photos': ids,
              'notice': response.exception == null
                  ? '已恢复食品资料和照片，请继续识别。'
                  : '上次拍照未完成，请重新拍摄。'
            })
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      return;
    }
    if (response.isEmpty) return;
    if (response.exception != null) {
      recoveryNotice = '上次图片选择未完成，请重新选择（${response.exception!.code}）。';
      return;
    }
    final recovered = response.files ??
        <XFile>[if (response.file != null) response.file!];
    if (recovered.isNotEmpty) {
      final draftRows = await records.db
          .query('app_settings', where: 'key=?', whereArgs: ['chat_draft']);
      final draft = draftRows.isEmpty
          ? <String, dynamic>{'text': '', 'attachments': []}
          : jsonMap(draftRows.single['value_json'] as String);
      final ids = List<String>.from(draft['attachments'] as List);
      if (ids.length + recovered.length > 3) {
        recoveryNotice = '聊天草稿最多保留 3 张图片，超出的照片未加入，请分次选择。';
      }
      for (final file in recovered) {
        if (ids.length < 3) {
          ids.add((await prepare(file))['id'] as String);
        } else {
          await _removePickerCopy(file);
        }
      }
      await records.db.insert(
          'app_settings',
          {
            'key': 'chat_draft',
            'value_json': jsonEncode({...draft, 'attachments': ids})
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      recoveredChatImages = true;
    }
  }

  Future<List<Json>> pick(bool camera, int currentCount,
      {bool restoreToChat = true}) async {
    require(currentCount < 3, '一条消息最多 3 张图片');
    // Android 回收拍照中的进程后，食品资料照片不能恢复成聊天草稿。
    if (!restoreToChat) {
      await records.db.insert('app_settings',
          {'key': 'library_photo_capture', 'value_json': 'true'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    try {
      final files = camera
          ? [await picker.pickImage(source: ImageSource.camera)]
              .whereType<XFile>()
              .toList()
          : await picker.pickMultiImage();
      require(files.length + currentCount <= 3, '一条消息最多 3 张图片，请重新选择');
      final result = <Json>[];
      try {
        for (final file in files) {
          result.add(await prepare(file));
        }
        return result;
      } catch (_) {
        for (final row in result) {
          await discard(row['id'] as String);
        }
        rethrow;
      }
    } finally {
      if (!restoreToChat) {
        await records.db.delete('app_settings',
            where: 'key=?', whereArgs: ['library_photo_capture']);
      }
    }
  }

  Future<Json> prepare(XFile source) async {
    try {
      final bytes = await source.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      final scale = math.min(1.0, 1600 / math.max(width, height));
      final compressed = await FlutterImageCompress.compressWithList(bytes,
          minWidth: (width * scale).round(),
          minHeight: (height * scale).round(),
          quality: 85,
          format: CompressFormat.jpeg,
          keepExif: false,
          autoCorrectionAngle: true);
      require(compressed.isNotEmpty && compressed.length <= 5 * 1024 * 1024,
          '图片压缩后仍超过 5 MiB，请裁剪或换一张清晰图片');
      final id = newId();
      final name = '$id.jpg';
      final file = fileFor(name);
      await file.writeAsBytes(compressed, flush: true);
      final row = {
        'id': id,
        'message_id': null,
        'relative_path': name,
        'mime_type': 'image/jpeg',
        'byte_length': compressed.length,
        'state': 'pending',
        'created_at_ms': nowMs()
      };
      try {
        await records.db.insert('chat_attachments', row);
      } catch (_) {
        await file.delete();
        rethrow;
      }
      return row;
    } finally {
      await _removePickerCopy(source);
    }
  }

  Future<void> _removePickerCopy(XFile source) async {
    final cache = (await getTemporaryDirectory()).path;
    final pickerCopy = File(source.path);
    if (p.isWithin(cache, pickerCopy.path) && await pickerCopy.exists()) {
      await pickerCopy.delete();
    }
  }

  File fileFor(String relative) {
    require(
        p.basename(relative) == relative && !p.isAbsolute(relative), '图片路径不合法');
    final path = p.normalize(p.join(root.path, relative));
    require(p.isWithin(root.path, path), '图片路径不在 APP 私有目录');
    return File(path);
  }

  Future<List<Json>> forMessage(String id) =>
      records.db.query('chat_attachments',
          where: "message_id=? AND state='pending'",
          whereArgs: [id],
          orderBy: 'created_at_ms,rowid');

  Future<List<Json>> contentFor(String messageId) async {
    final rows = await forMessage(messageId);
    final content = <Json>[];
    for (final row in rows) {
      final file = fileFor(row['relative_path'] as String);
      require(await file.exists(), '图片副本已丢失，请重新选择', 'image_missing');
      content.add({
        'type': 'input_image',
        'image_url':
            'data:image/jpeg;base64,${base64Encode(await file.readAsBytes())}',
        'detail': 'auto'
      });
    }
    return content;
  }

  Future<void> discard(String id) async {
    await records.db.update('chat_attachments', {'state': 'delete_pending'},
        where: 'id=?', whereArgs: [id]);
    await cleanup();
  }

  Future<void> discardMessage(String id) async {
    await records.db.update('chat_attachments', {'state': 'delete_pending'},
        where: 'message_id=?', whereArgs: [id]);
    await cleanup();
  }

  Future<void> saveSummary(
      String operationId, String messageId, Json summary) async {
    await records.db.transaction((tx) async {
      await tx.update(
          'operations',
          {
            'vision_summary_json': jsonEncode(summary),
            'stage': 'text',
            'updated_at_ms': nowMs()
          },
          where: 'id=?',
          whereArgs: [operationId]);
    });
  }

  Future<void> cleanup({bool orphanDrafts = false}) async {
    if (orphanDrafts) {
      final saved = await records.db
          .query('app_settings', where: 'key=?', whereArgs: ['chat_draft']);
      final draft = saved.isEmpty
          ? <String, dynamic>{}
          : jsonMap(saved.single['value_json'] as String);
      final ids = (draft['attachments'] as List? ?? []).toSet();
      final libraryRows = await records.db.query('app_settings',
          where: 'key=?', whereArgs: ['library_editor_draft']);
      if (libraryRows.isNotEmpty) {
        ids.addAll(jsonMap(libraryRows.single['value_json'] as String)['photos']
                as List? ??
            []);
      }
      final unbound = await records.db
          .query('chat_attachments', where: 'message_id IS NULL');
      for (final row in unbound) {
        if (!ids.contains(row['id'])) {
          await records.db.update(
              'chat_attachments', {'state': 'delete_pending'},
              where: 'id=?', whereArgs: [row['id']]);
        }
      }
    }
    final rows = await records.db.query('chat_attachments');
    final registered = rows.map((e) => e['relative_path'] as String).toSet();
    for (final row in rows.where((r) => r['state'] == 'delete_pending')) {
      final file = fileFor(row['relative_path'] as String);
      if (await file.exists()) await file.delete();
      await records.db
          .delete('chat_attachments', where: 'id=?', whereArgs: [row['id']]);
    }
    await for (final entry in root.list(followLinks: false)) {
      if (entry is File && !registered.contains(p.basename(entry.path))) {
        await entry.delete();
      }
    }
  }
}
