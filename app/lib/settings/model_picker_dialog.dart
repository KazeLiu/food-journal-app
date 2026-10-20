import 'package:flutter/material.dart';

import '../core/widgets.dart';

Future<String?> showModelPickerDialog(BuildContext context,
    {required String title, required List<String> models}) async {
  final controller = TextEditingController();
  try {
    return await showInputDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(builder: (context, update) {
              final matches = models
                  .where((id) =>
                      id.toLowerCase().contains(controller.text.toLowerCase()))
                  .toList();
              return AlertDialog(
                  title: Text(title),
                  content: SizedBox(
                      width: 400,
                      height: 360,
                      child: Column(children: [
                        TextField(
                            controller: controller,
                            decoration:
                                const InputDecoration(labelText: '搜索模型 ID'),
                            onChanged: (_) => update(() {})),
                        Expanded(
                            child: matches.isEmpty
                                ? const Center(child: Text('没有匹配的模型'))
                                : ListView.builder(
                                    itemCount: matches.length,
                                    itemBuilder: (context, index) => ListTile(
                                        title: Text(matches[index]),
                                        onTap: () => Navigator.pop(
                                            context, matches[index])))),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'))
                  ]);
            }));
  } finally {
    controller.dispose();
  }
}
