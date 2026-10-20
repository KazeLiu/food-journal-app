import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/data.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../records/editors.dart';
import '../records/record_card.dart';

class CalendarPage extends StatefulWidget {
  final AppServices s;
  const CalendarPage(this.s, {super.key});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime month = DateTime.parse(widget.s.day.value);
  AppServices get s => widget.s;
  @override
  void initState() {
    super.initState();
    s.day.addListener(_select);
  }

  @override
  void dispose() {
    s.day.removeListener(_select);
    super.dispose();
  }

  void _select() {
    setState(() {
      month = DateTime.parse(s.day.value);
    });
  }

  Future<Json> load() async => {
        'marks': await s.records.monthMarks(month),
        'totals': await s.records.totals(s.day.value),
        'meals': await s.records.meals(s.day.value),
        'weights': await s.records.weights(date: s.day.value, limit: null),
        'exercises': await s.records.exercises(s.day.value),
        'exercise_totals': await s.records.exerciseTotals(s.day.value)
      };
  @override
  Widget build(BuildContext context) => SafeArea(
          child: Column(children: [
        AppBar(title: const Text('我的记录'), actions: [
          IconButton(
              tooltip: '体重历史',
              icon: const Icon(Icons.monitor_weight_outlined),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => WeightHistory(s))))
        ]),
        Expanded(
            child: AnimatedBuilder(
                animation: s.records,
                builder: (context, _) => DataView<Json>(
                    future: load(),
                    builder: (data) {
                      final marks = data['marks'] as Map<String, Set<String>>;
                      final totals = data['totals'] as Json;
                      final dayMeals = (data['meals'] as List).cast<Json>();
                      final weights = (data['weights'] as List).cast<Json>();
                      final exercises =
                          (data['exercises'] as List).cast<Json>();
                      final exerciseTotals = data['exercise_totals'] as Json;
                      return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      '${month.year} 年 ${month.month} 月',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge)),
                              IconButton(
                                  tooltip: '上个月',
                                  onPressed: () => setState(() {
                                        month = DateTime(
                                            month.year, month.month - 1);
                                      }),
                                  icon: const Icon(Icons.chevron_left)),
                              IconButton(
                                  tooltip: '下个月',
                                  onPressed: () => setState(() {
                                        month = DateTime(
                                            month.year, month.month + 1);
                                      }),
                                  icon: const Icon(Icons.chevron_right))
                            ]),
                            Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                    onPressed: () {
                                      s.day.value = today();
                                      setState(() {
                                        month = DateTime.now();
                                      });
                                    },
                                    child: const Text('回今天'))),
                            LayoutBuilder(builder: (context, constraints) {
                              final first =
                                  DateTime(month.year, month.month, 1);
                              final count =
                                  DateTime(month.year, month.month + 1, 0).day;
                              final cells =
                                  ((first.weekday - 1 + count) / 7).ceil() * 7;
                              final width =
                                  math.max(336.0, constraints.maxWidth);
                              final scale =
                                  MediaQuery.textScalerOf(context).scale(16) /
                                      16;
                              return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                      width: width,
                                      child: Column(children: [
                                        Row(
                                            children: [
                                          '一',
                                          '二',
                                          '三',
                                          '四',
                                          '五',
                                          '六',
                                          '日'
                                        ]
                                                .map((e) => Expanded(
                                                    child: Center(
                                                        child: Text(e,
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .bodySmall))))
                                                .toList()),
                                        const SizedBox(height: 8),
                                        GridView.builder(
                                            shrinkWrap: true,
                                            physics:
                                                const NeverScrollableScrollPhysics(),
                                            itemCount: cells,
                                            gridDelegate:
                                                SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount: 7,
                                                    mainAxisExtent: 56 * scale),
                                            itemBuilder: (context, index) {
                                              final day =
                                                  index - first.weekday + 2;
                                              if (day < 1 || day > count) {
                                                return const SizedBox.shrink();
                                              }
                                              final key = dateKey(DateTime(
                                                  month.year,
                                                  month.month,
                                                  day));
                                              final selected =
                                                  key == s.day.value;
                                              final isToday = key == today();
                                              final food =
                                                  marks['food']!.contains(key);
                                              final weight = marks['weight']!
                                                  .contains(key);
                                              final exercise =
                                                  marks['exercise']!
                                                      .contains(key);
                                              return Semantics(
                                                  label:
                                                      '$key${isToday ? ' 今天' : ''}${food ? ' 有饮食' : ''}${weight ? ' 有体重' : ''}${exercise ? ' 有运动' : ''}',
                                                  selected: selected,
                                                  button: true,
                                                  child: InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              16),
                                                      onTap: () =>
                                                          s.day.value = key,
                                                      child: Container(
                                                          margin:
                                                              const EdgeInsets
                                                                  .all(2),
                                                          decoration: BoxDecoration(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                      14),
                                                              color: selected
                                                                  ? Theme.of(context)
                                                                      .colorScheme
                                                                      .primaryContainer
                                                                  : null,
                                                              border: isToday
                                                                  ? Border.all(
                                                                      color: Theme.of(context)
                                                                          .colorScheme
                                                                          .onPrimaryContainer)
                                                                  : null),
                                                          child: Column(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                Text('$day',
                                                                    style: TextStyle(
                                                                        fontWeight: selected ||
                                                                                isToday
                                                                            ? FontWeight.w700
                                                                            : FontWeight.normal)),
                                                                const SizedBox(
                                                                    height: 4),
                                                                Row(
                                                                    mainAxisAlignment:
                                                                        MainAxisAlignment
                                                                            .center,
                                                                    children: [
                                                                      if (food)
                                                                        _dot(JournalColors.of(context)
                                                                            .foodMark),
                                                                      if (weight)
                                                                        _dot(JournalColors.of(context)
                                                                            .weightMark),
                                                                      if (exercise)
                                                                        _dot(JournalColors.of(context)
                                                                            .exerciseMark)
                                                                    ])
                                                              ]))));
                                            }),
                                      ])));
                            }),
                            const SizedBox(height: 12),
                            Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _dot(JournalColors.of(context).foodMark),
                                  const Text('饮食'),
                                  const SizedBox(width: 24),
                                  _dot(JournalColors.of(context).weightMark),
                                  const Text('体重'),
                                  const SizedBox(width: 24),
                                  _dot(JournalColors.of(context).exerciseMark),
                                  const Text('运动')
                                ]),
                            SectionTitle(s.day.value,
                                trailing: PopupMenuButton<String>(
                                    tooltip: '新增记录',
                                    icon: const Icon(Icons.add),
                                    onSelected: (value) {
                                      if (value == 'meal') {
                                        openMealEditor(context, s,
                                            date: s.day.value);
                                      } else if (value == 'exercise') {
                                        openExerciseEditor(context, s,
                                            date: s.day.value);
                                      } else {
                                        openWeightEditor(context, s,
                                            date: s.day.value);
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                          PopupMenuItem(
                                              value: 'meal',
                                              child: Text('手动记饮食')),
                                          PopupMenuItem(
                                              value: 'weight',
                                              child: Text('记录体重')),
                                          PopupMenuItem(
                                              value: 'exercise',
                                              child: Text('记录运动'))
                                        ])),
                            if (dayMeals.isEmpty &&
                                weights.isEmpty &&
                                exercises.isEmpty)
                              const EmptyView('这一天没有记录，没关系'),
                            if (dayMeals.isNotEmpty) ...[
                              Text(calorieText(totals),
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall),
                              const SizedBox(height: 16),
                              NutritionSummary(totals),
                              for (final type in mealNames.keys)
                                if (dayMeals
                                    .any((m) => m['meal_type'] == type)) ...[
                                  SectionTitle(mealNames[type]!),
                                  ...dayMeals
                                      .where((m) => m['meal_type'] == type)
                                      .map((m) => Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 12),
                                          child: RecordCard(s,
                                              table: 'meals',
                                              id: m['id'] as String,
                                              actionId: m['origin_action_id']
                                                  as String))),
                                ]
                            ],
                            if (exercises.isNotEmpty) ...[
                              const SectionTitle('当天的运动'),
                              Text(
                                  '${exerciseTotals['exercise_count']} 次运动 · ${exerciseTotals['missing_duration'] == exerciseTotals['exercise_count'] ? '时长未知' : '已记录 ${numberText(exerciseTotals['duration_minutes'] as num)} 分钟'}'),
                              Text(exerciseTotals['missing_calories'] ==
                                      exerciseTotals['exercise_count']
                                  ? '运动消耗未知'
                                  : '已知运动消耗合计 ${exerciseTotals['calories_kcal']} kcal（含估算）'),
                              if (exerciseTotals['missing_duration'] > 0 ||
                                  exerciseTotals['missing_calories'] > 0)
                                Text(
                                    '${exerciseTotals['missing_duration']} 次时长未知 · ${exerciseTotals['missing_calories']} 次消耗未知',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              const SizedBox(height: 12),
                              ...exercises.map((e) => Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: RecordCard(s,
                                      table: 'exercise_records',
                                      id: e['id'] as String,
                                      actionId:
                                          e['origin_action_id'] as String))),
                            ],
                            if (weights.isNotEmpty) ...[
                              const SectionTitle('当天的每次体重'),
                              ...weights.map((w) => Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: RecordCard(s,
                                      table: 'weight_records',
                                      id: w['id'] as String,
                                      actionId:
                                          w['origin_action_id'] as String)))
                            ],
                            OutlinedButton.icon(
                                onPressed: () {
                                  s.goChat({
                                    'local_date': s.day.value,
                                    'label': '记录或查询 ${s.day.value}'
                                  });
                                },
                                icon: const Icon(Icons.auto_awesome_outlined),
                                label: const Text('聊聊这一天')),
                          ]);
                    }))),
      ]));
  Widget _dot(Color color) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)));
}

class WeightHistory extends StatefulWidget {
  final AppServices s;
  const WeightHistory(this.s, {super.key});
  @override
  State<WeightHistory> createState() => _WeightHistoryState();
}

class _WeightHistoryState extends State<WeightHistory> {
  String unit = 'jin';
  int limit = 50;
  @override
  void initState() {
    super.initState();
    widget.s.settings.get('weight_unit', 'jin').then((v) {
      if (mounted) {
        setState(() {
          unit = v as String;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('体重历史')),
      floatingActionButton: FloatingActionButton(
          tooltip: '记录体重',
          onPressed: () => openWeightEditor(context, widget.s),
          child: const Icon(Icons.add)),
      body: AnimatedBuilder(
          animation: widget.s.records,
          builder: (context, _) => DataView<List<Json>>(
              future: widget.s.records.weights(limit: limit + 1),
              builder: (rows) => ListView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 100),
                      children: [
                        SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: 'jin', label: Text('斤')),
                              ButtonSegment(value: 'kg', label: Text('公斤'))
                            ],
                            selected: {
                              unit
                            },
                            onSelectionChanged: (v) => setState(() {
                                  unit = v.single;
                                })),
                        if (rows.isEmpty)
                          const EmptyView('先记下第一次体重',
                              body: '每天可以记录多次，不覆盖、不取平均。'),
                        if (rows.isNotEmpty) ...[
                          const SectionTitle('最近一次已注明时刻的测量'),
                          Text(
                              rows.first['occurred_at_ms'] == null
                                  ? '还没有注明时刻的测量'
                                  : '${numberText((rows.first['grams'] as int) / (unit == 'jin' ? 500 : 1000), 2)} ${unit == 'jin' ? '斤' : 'kg'}',
                              style:
                                  Theme.of(context).textTheme.headlineMedium),
                          if (rows.first['occurred_at_ms'] != null)
                            Text(
                                '${rows.first['local_date']} ${rows.first['local_time']}'),
                          const SectionTitle('全部测量（仅注明时段或日期的按录入顺序单列）'),
                          ...rows.take(limit).map((w) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                  '${numberText((w['grams'] as int) / (unit == 'jin' ? 500 : 1000), 2)} ${unit == 'jin' ? '斤' : 'kg'}'),
                              subtitle: Text(recordDateTime(w)),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => openRecord(context, widget.s,
                                  'weight_records', w['id'] as String))),
                          if (rows.length > limit)
                            TextButton(
                                onPressed: () => setState(() {
                                      limit += 50;
                                    }),
                                child: const Text('加载更多')),
                        ],
                      ]))));
}
