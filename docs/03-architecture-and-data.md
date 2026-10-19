# 03 架构与数据

## 1. 技术选择

| 项目 | V1 选择 | 理由 |
| --- | --- | --- |
| 客户端 | Flutter stable / Dart，Android | 沿用产品决定 |
| UI | Material 组件 + 自定义颜色和气泡 | 保持原生交互，不引入整套 UI 框架 |
| 状态 | `ChangeNotifier` / `ValueNotifier`，构造函数注入 | 三个主页面不需要额外状态管理框架 |
| 导航 | `Navigator`，底部页保留状态 | 无复杂路由或外部深链需求 |
| 数据库 | `sqflite` + `path` | 直接 SQL、事务和版本迁移，适合本地关系数据 |
| 网络 | `http` | `GET /models` 与 Responses API `POST /responses`；不启用透明重试 |
| Key | `flutter_secure_storage` | 凭据不进入业务 SQLite |
| 图片 | `image_picker` + `flutter_image_compress` | 系统拍照 / 相册与原生压缩 |
| 私有目录 | `path_provider` | 临时图、导出中间文件和安全副本 |
| 文件导入导出 | `flutter_file_dialog` | Android 系统文件选择与保存 |
| 标识符 | `uuid` | 生成操作、消息、餐、食物、体重 ID |
| 日期与显示 | Dart `DateTime` 和本地格式化函数 | 本版不做复杂时区选择和多语言管理 |

Android 的初始最低版本设为 API 24，与选定图片 / 文件插件的当前要求一致。`compileSdk / targetSdk` 按实际 Flutter stable 工程及依赖要求确定。开始编码时记录确切 Flutter、Dart、JDK、Gradle、插件版本并提交应用的 `pubspec.lock`；本设计不把“latest”当可复现版本号。

不引入 ORM、代码生成、依赖注入容器、通用事件总线、向量库、后台任务框架或完整 AI Agent SDK。若后续出现具体问题，再按证据选择是否需要。

相关能力来自 Flutter 和包维护者文档：[SQLite 使用](https://docs.flutter.dev/cookbook/persistence/sqlite)、[sqflite](https://pub.dev/packages/sqflite)、[凭据存储](https://pub.dev/packages/flutter_secure_storage)、[图片选择](https://pub.dev/packages/image_picker)。全部参考资料见 07。

## 2. 模块职责

```text
页面 / ViewModel
       │
       ├─ RecordRepository ───── SQLite
       │      └─ 本地新增、编辑、删除、查询、汇总
       │
       ├─ ChatCoordinator
       │      ├─ ContextBuilder：近期聊天与当前记录
       │      ├─ AiGateway：同类型主备各一次
       │      ├─ ProtocolParser：JSON 与操作校验
       │      └─ OperationCommitter：事务、版本、回执
       │
       ├─ BackfillCoordinator ── AiGateway + RecordRepository
       ├─ ImageService ──────── 私有临时副本与清理
       ├─ BackupService ─────── 版本化 JSON 与事务恢复
       └─ SettingsRepository ── SQLite 非敏感设置 + 安全存储
```

这是职责边界，不要求每条箭头都拆成接口和实现类。普通具体类足够；只在网络、文件、数据库等外部边界保留清晰输入输出。

### 数据流

1. 保存用户消息和稳定 `operation_id`，然后才发网络请求。
2. 前台按队列取下一条；轮到执行时按其文字准备有限日期候选，与此前已提交记录一起生成快照，AI 不能查询数据库或输出 SQL。
3. AI 返回协议 JSON；客户端解析、核对目标 ID 和版本，形成待提交操作。
4. 本地事务同时写业务变更、成功回执和操作提交状态。
5. 提交成功后刷新相关日期和卡片，并清理完成任务的图片。
6. 正常前台聊天成功后，独立触发空热量补算。补算不能阻塞或递归触发聊天。

## 3. 预计工程目录

以下路径相对于未来 Flutter 工程目录 `app/`；本次只创建文档，根目录 README 和 docs 不由工程生成器覆盖。

```text
lib/
  main.dart
  app.dart
  core/
    database/app_database.dart
    database/migrations.dart
    network/ai_gateway.dart
    network/endpoint_config.dart
    storage/credential_store.dart
    storage/image_service.dart
    theme/app_theme.dart
    time/record_time.dart
  records/
    record_models.dart
    record_repository.dart
    record_editor.dart
    record_detail_page.dart
  chat/
    chat_page.dart
    chat_view_model.dart
    chat_coordinator.dart
    context_builder.dart
    ai_protocol.dart
    protocol_parser.dart
    operation_committer.dart
    prompts.dart
  calendar/
    calendar_page.dart
    calendar_view_model.dart
  settings/
    settings_page.dart
    settings_repository.dart
    api_settings_page.dart
  data_management/
    backfill_coordinator.dart
    backup_service.dart
    data_management_page.dart
```

共享编辑器只维护一次；记录卡片、日历、顶部统计都查询 `RecordRepository`。页面不直接拼接 SQL，AI 模块也不绕过仓库改数据。

## 4. 数据约定

### 4.1 ID、数值与来源

- 所有实体 ID 为客户端 UUID 字符串。AI 只给新实体一个本次操作内的 `client_ref`，不生成真实数据库 ID。
- `operation_id` 标识一次用户提交或一次补算批次；换模型、重试网络都不更换该逻辑操作 ID。
- `version` 初始为 1，每次记录变化加 1；用于防止 AI 结果覆盖用户后续修改。
- 热量单位固定 kcal，用可空整数。0 是有效数值；未知用 NULL。
- 热量来源：`unknown`（空值）、`ai`（AI 估算）、`user`（用户明确填写）。
- 体重统一值用整数克；输入和显示保留原单位，避免反复浮点转换。
- 份量用自然语言 `portion_text`，不引入标准份量单位表。

### 4.2 时间

每条餐和体重都保存：

| 字段 | 含义 |
| --- | --- |
| `local_date` | 发生日期，`YYYY-MM-DD`，日历与统计的权威归属 |
| `local_time` | 已知发生时间，`HH:mm`；未注明时为 NULL |
| `occurred_at_ms` | 已知时刻对应 UTC 毫秒；只有日期时为 NULL |
| `utc_offset_minutes` | 该已知时刻采用的 UTC 偏移；只有日期时为 NULL |
| `created_at_ms` | 实际录入的 UTC 毫秒，不随改日期变化 |
| `updated_at_ms` | 最近修改的 UTC 毫秒 |

明确日期、餐别但没有时间时不伪造 12:00。默认“现在”的记录可以用发送时刻。显式历史时间根据手机该日期的本地时间规则转换，不直接套用今天的 UTC 偏移。

统计不使用 `created_at_ms` 推断进食日期，也不按手机当前时区重新转换历史 UTC 值来分组。

## 5. SQLite V1 表结构

数据库文件名 `food_journal.db`，schema version 为 1。下列 DDL 是字段与约束的基准，实际代码使用参数化 SQL。

```sql
CREATE TABLE operations (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('chat', 'manual', 'backfill')),
  status TEXT NOT NULL CHECK (status IN (
    'pending', 'in_flight', 'ready', 'committed',
    'failed', 'interrupted', 'cancelled'
  )),
  mode TEXT NOT NULL CHECK (mode IN ('text', 'vision', 'local')),
  reference_time_json TEXT NOT NULL,
  queue_order INTEGER UNIQUE,
  reply_to_operation_id TEXT REFERENCES operations(id) ON DELETE SET NULL,
  request_generation INTEGER NOT NULL DEFAULT 0,
  model_id TEXT,
  plan_json TEXT,
  receipt_json TEXT,
  error_code TEXT,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY,
  operation_id TEXT REFERENCES operations(id) ON DELETE SET NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  content_kind TEXT NOT NULL CHECK (content_kind IN (
    'text', 'receipt', 'clarification', 'failure', 'notice'
  )),
  body_text TEXT NOT NULL,
  delivery_status TEXT NOT NULL CHECK (delivery_status IN (
    'queued', 'saved', 'processing', 'failed', 'interrupted',
    'cancelled', 'manually_resolved'
  )),
  image_count INTEGER NOT NULL DEFAULT 0
    CHECK (image_count BETWEEN 0 AND 3),
  record_refs_json TEXT,
  created_at_ms INTEGER NOT NULL,
  UNIQUE (operation_id, role)
);

CREATE TABLE chat_attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT REFERENCES chat_messages(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL UNIQUE,
  mime_type TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  state TEXT NOT NULL CHECK (state IN ('pending', 'delete_pending')),
  created_at_ms INTEGER NOT NULL
);

CREATE TABLE meals (
  id TEXT PRIMARY KEY,
  origin_operation_id TEXT NOT NULL REFERENCES operations(id),
  client_ref TEXT NOT NULL,
  source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
  local_date TEXT NOT NULL,
  local_time TEXT,
  occurred_at_ms INTEGER,
  utc_offset_minutes INTEGER,
  meal_type TEXT NOT NULL CHECK (meal_type IN (
    'breakfast', 'lunch', 'dinner', 'other'
  )),
  raw_description TEXT NOT NULL,
  note TEXT,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE (origin_operation_id, client_ref)
);

CREATE TABLE food_items (
  id TEXT PRIMARY KEY,
  meal_id TEXT NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
  origin_operation_id TEXT NOT NULL REFERENCES operations(id),
  client_ref TEXT NOT NULL,
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  portion_text TEXT,
  calories_kcal INTEGER CHECK (calories_kcal >= 0),
  calorie_source TEXT NOT NULL CHECK (
    calorie_source IN ('unknown', 'ai', 'user')
  ),
  estimation_note TEXT,
  note TEXT,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  CHECK (
    (calories_kcal IS NULL AND calorie_source = 'unknown') OR
    (calories_kcal IS NOT NULL AND calorie_source IN ('ai', 'user'))
  ),
  UNIQUE (origin_operation_id, client_ref)
);

CREATE TABLE weight_records (
  id TEXT PRIMARY KEY,
  origin_operation_id TEXT NOT NULL REFERENCES operations(id),
  client_ref TEXT NOT NULL,
  source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
  local_date TEXT NOT NULL,
  local_time TEXT,
  occurred_at_ms INTEGER,
  utc_offset_minutes INTEGER,
  input_value TEXT NOT NULL,
  input_unit TEXT NOT NULL CHECK (input_unit IN ('jin', 'kg')),
  grams INTEGER NOT NULL CHECK (grams > 0),
  raw_description TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE (origin_operation_id, client_ref)
);

CREATE TABLE app_settings (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);

CREATE INDEX idx_messages_time ON chat_messages(created_at_ms, id);
CREATE INDEX idx_meals_day ON meals(local_date, meal_type);
CREATE INDEX idx_food_meal ON food_items(meal_id);
CREATE INDEX idx_food_pending ON food_items(calories_kcal);
CREATE INDEX idx_weight_day ON weight_records(local_date, local_time);
CREATE INDEX idx_attachments_state ON chat_attachments(state);
```

### 表间约束的使用

- 建库连接在 `onConfigure` 中开启 `PRAGMA foreign_keys = ON`。外键是否生效由连接配置决定，不能只写 DDL。[SQLite 外键说明](https://www.sqlite.org/foreignkeys.html)
- `chat_messages` 的 `(operation_id, role)` 约束用于同一操作最多一条用户消息、一条助手结果。重试更新同一个助手结果，不不断追加失败气泡；不同用户提交使用不同操作。
- 聊天入队事务内分配递增 `queue_order`，不用 UUID 大小或相同毫秒时间猜测顺序；manual / backfill 无队列顺序，可为 NULL。
- 回答澄清的操作通过可空 `reply_to_operation_id` 关联原事项，允许在暂停点优先处理，再恢复原有队列；原操作仍保持未写业务事实的澄清结果。
- 没有聊天来源的手动新增和补算，可以没有关联聊天行；补算汇总提示可以作为 `operation_id = NULL` 的 notice 消息。
- 草稿图片先登记为 message_id=NULL，并由 chat_draft 的附件ID列表引用；发送事务把它们绑定到真实用户消息，再清空该份草稿引用。这样未发送图片也能恢复，不会被当成孤立文件清除。
- 删除聊天通过 `ON DELETE SET NULL` 断开来源；操作账本不级联删除，因此不丢去重凭据。
- 删除整餐才级联删除食物；不是从聊天行级联到饮食。
- 修改食物时不重新生成 ID。新增食物用当前操作的 `origin_operation_id / client_ref`，不是沿用原餐的创建操作。
- 食物变化与所属餐的 `version` 同步递增，便于阻止“整餐修改”覆盖已经变动的子项。
- `plan_json` 只保存已校验的客户端操作提案，用于识别成功但保存失败后的本地恢复；不保存图片、Key、HTTP 头或原始请求体。
- 已提交的操作以 `receipt_json` 为恢复依据，可清空 `plan_json`，避免长期保存重复提案。
- `record_refs_json` 仅保存类型与 ID，例如 `[{"type":"food","id":"..."}]`；打开时查当前表，不把历史卡片当事实来源。

## 6. 设置结构

`app_settings` 只保存少量已知键，不建立动态配置平台：

| Key | 值 |
| --- | --- |
| `ai_profile` | `base_url`、四个模型 ID、当前 HTTP 风险确认状态 |
| `weight_unit` | `jin` 或 `kg`，默认 `jin` |
| `chat_draft` | 未发送文字及临时附件 ID；实际图片不放入 JSON |
| `privacy_notice_accepted` | 是否已看过外部 AI 处理说明 |

API Key 和绑定的规范化 Base URL 一起放在安全存储。修改 Base URL 后，必须重新确认 / 输入对应 Key，不能把旧 Key 自动发送给新地址。仅修改模型 ID 不需要重新输入 Key。

模型列表缓存只为当前设置页会话服务，不作为模型能力或永久配置事实，也不需要单独数据库表。

## 7. 查询与计算

### 日热量和空值数量

```sql
SELECT
  COUNT(*) AS item_count,
  COALESCE(SUM(f.calories_kcal), 0) AS known_calories_kcal,
  SUM(CASE WHEN f.calories_kcal IS NULL THEN 1 ELSE 0 END)
    AS pending_item_count
FROM food_items f
JOIN meals m ON m.id = f.meal_id
WHERE m.local_date = ?;
```

`SUM` 的 0 只用于运算，展示必须同时看 `item_count` 和 `pending_item_count`，使用 01 的口径；无食物或全部未知时不能显示成“已摄入 0”。无行时 `pending_item_count` 在查询返回边界明确转为 0。

### 餐数、日历点与时间排序

- 餐数：当天有食物的 `breakfast / lunch / dinner` 去重计数。
- 其他次数：当天 `other` 的非空餐数量。
- 月历：按月起止日期查询 `meals.local_date` 与 `weight_records.local_date` 的去重集合；不把每个日期循环查一次。
- 同日已知时间按时间排序；未注明时间的餐按餐别与录入顺序，体重在“时间未注明”区按录入顺序。
- 餐小计在同一查询结果内求和，不能将餐行与多条体重直接 JOIN 后求和，避免笛卡尔重复。

### 体重换算

输入限定普通十进制正数字符串、最多两位小数；转换为百分之一单位的整数后计算：

```text
132 斤：13200 × 5 = 66000 克
66 公斤：6600 × 10 = 66000 克
```

显示时从整数克换算到当前偏好单位，保留合理小数并去掉无意义尾零；原始输入文本和单位始终保留。

## 8. 原子性与刷新

- 一次普通聊天涉及的全部业务动作，连同助手成功消息、操作状态，在一个 SQLite 事务里提交。
- 不在事务中发网络、压缩图片或弹对话框。
- sqflite 事务内部只使用事务对象；错误向外抛出，不能吞异常让剩余动作提交。[sqflite 事务说明](https://pub.dev/packages/sqflite)
- 仓库在提交后发送一次轻量变更通知，包含旧 / 新日期集合。相关 ViewModel 重读当前查询，不维护第二套总数。
- 补算使用逐项条件更新以跳过过期结果，其事务规则见 05；与普通聊天的“全部动作一起提交”区分。
- schema 升级只增加明确迁移，不在打开失败时删库重建。降级或版本不支持时保留文件并提示，不清空用户记录。
