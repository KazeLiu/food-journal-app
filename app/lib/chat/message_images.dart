import 'dart:io';

import 'package:flutter/material.dart';

import '../core/data.dart';
import '../core/image_service.dart';

Future<void> openImagePreview(BuildContext context, File file) =>
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => ImagePreview(file)));

class MessageImages extends StatelessWidget {
  final ImageService images;
  final String messageId;
  const MessageImages(this.images, {required this.messageId, super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Json>>(
      future: images.forMessage(messageId),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Text('图片预览暂时无法读取');
        if (!snapshot.hasData) {
          return const SizedBox(
              width: 80,
              height: 80,
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))));
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) return const Text('此消息的图片预览已不可用');
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < rows.length; i++)
            Tooltip(
                message: '查看第 ${i + 1} 张图片',
                child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => openImagePreview(context,
                        images.fileFor(rows[i]['relative_path'] as String)),
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                            images.fileFor(rows[i]['relative_path'] as String),
                            width: 80,
                            height: 80,
                            cacheWidth: 240,
                            fit: BoxFit.cover,
                            semanticLabel: '发送的第 ${i + 1} 张图片',
                            errorBuilder: (_, __, ___) => const SizedBox(
                                width: 80,
                                height: 80,
                                child: Icon(Icons.broken_image_outlined))))))
        ]);
      });
}

class ImagePreview extends StatelessWidget {
  final File file;
  const ImagePreview(this.file, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('图片预览')),
      body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context),
          child: Center(
              child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Image.file(file,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('图片预览已不可用')))))));
}
