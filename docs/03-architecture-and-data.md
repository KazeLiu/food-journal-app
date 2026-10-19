# 03 架构与数据

## 1. 技术选择

| 部分 | 选择 | 用途 |
| --- | --- | --- |
| 客户端 | Flutter stable / Dart，Android | 三页与系统交互 |
| 状态 / 导航 | ChangeNotifier、ValueNotifier、构造注入、Navigator | 页面状态保留，不引入容器或事件总线 |
| 数据 | sqflite + path | 参数化 SQL、事务、迁移 |
| 网络 | http | 模型列表、Responses JSON / SSE、取消；关闭透明重试 |
| 凭据 | flutter_secure_storage | Key 与规范化服务地址绑定 |
| 图片 | image_picker、flutter_image_compress | 系统选择器、临时副本和保守压缩 |
| 文件 | path_provider、flutter_file_dialog | 私有目录与系统导入导出 |
| 标识 | uuid | 消息、操作、记录、资料 ID |
| 备份加密 | cryptography，实施时固定版本 | PBKDF2-HMAC-SHA256 派生、AES-256-GCM；不自写密码算法 |

初始最低 Android API 24。实际 Flutter、Dart、JDK、Gradle、compileSdk / targetSdk 和依赖版本在工程创建时核对并记录，提交 pubspec.lock，不把 latest 当版本。

不引入自有服务器、ORM / 代码生成、向量库、后台调度框架或通用 Agent SDK。历史关键词查询先用有界参数化 LIKE；小规模本地数据不需要搜索平台。

## 2. 模块与数据流

```text
页面 / ViewModel
 ├─ RecordRepository：本地记录、汇总、历史查询、版本
 ├─ ChatCoordinator：FIFO、定向回答、停止、阶段恢复
 │   ├─ ContextBuilder：参考时间、近期对话、对象、授权资料
 │   ├─ AiGateway：Responses、SSE、每阶段主备一次
 │   ├─ ProtocolParser：完整JSON、流式reply、字段与引用
 │   ├─ LocalLookup：受限只读查询，不接受SQL
 │   └─ ActionCommitter：独立子操作事务、回执、撤销
 ├─ LibraryRepository / MemoryRepository：确认资料和偏好
 ├─ BackfillCoordinator：只补缺失、让出用户消息
 ├─ ImageService：临时副本、摘要和清理
 ├─ BackupService：快照、CSV、加密、恢复
 └─ SettingsRepository：普通设置、安全凭据
```

职责不等于每项都要拆接口 / 实现类，普通具体类足够。共享仓库统一供卡片、日历、搜索与汇总使用，页面和 AI 不直接拼 SQL。

发送事务保存消息、operation、queue_order、参考时间、定向对象和附件归属。执行时刷新当前数据快照；D03 暂经 vision 摘要持久化后转 text。文本返回完整提案，校验并保存子操作计划，然后逐个完整单位提交。实际提交后生成卡片，正常聊天成功且队列空闲时触发补算。

## 3. 预计工程目录

未来源码位于 app/，不覆盖根 README / docs。

```text
app/lib/
  main.dart、app.dart
  core/database/（建库、迁移）
  core/network/（endpoint、Responses、SSE）
  core/storage/（Key、图片）
  core/theme/、core/time/
  records/（模型、仓库、详情、编辑器、撤销）
  chat/（页面、协调器、上下文、提示词、协议、提交器）
  calendar/（月历、日详情、体重历史）
  search/（消息搜索与本地只读查询）
  library/（食品资料、确认卡、管理）
  memory/（授权偏好、建议与管理）
  settings/（接口、单位、外观）
  data_management/（补算、CSV、备份、恢复）
```

D01 直接编辑、D02 通用引用、D03 两阶段图片均为 09 中暂定值；数据库中的相关字段已明确标注用途，用户确认后才能落实对应实现。

## 4. 统一约定

- ID 为客户端 UUID。AI 新对象只给本次 `client_ref`，不能生成数据库真实 ID。
- `operation_id` 是一次用户提交；`action_id` 是其中一个可独立提交 / 重试 / 撤销的事项。模型的 action_key 仅在保存计划时映射一次，后续沿用客户端 ID。
- `version` 每次实体变化递增，撤销也不回退版本。删除采用软删除，以保留撤销和引用信息；普通查询一律排除 deleted_at_ms 非空行。
- 热量可空整数，营养素可空非负数；展示精度与存储原数值分开。每字段来源 `unknown / ai / user / label / library`，空值仅配 unknown。
- 当前食用量与资料库营养基准分开；历史食物保存已经换算的实际值和来源快照，不实时引用会变化的库值计算。
- 时间使用 local_date（发生日期权威）、可空 local_time / occurred_at_ms / utc_offset_minutes，另存 created_at_ms / updated_at_ms。未知时刻不伪造。

## 5. SQLite schema 1

当前没有已发行数据库；以下是未来首版建库契约。启用 `PRAGMA foreign_keys = ON`，应用写入边界验证枚举、JSON 结构和数值配套，外键不能只声明不启用。

```sql
CREATE TABLE operations (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('chat','manual','backfill','undo')),
  status TEXT NOT NULL CHECK(status IN (
    'pending','running','waiting_input','waiting_confirmation','ready',
    'completed','partial','failed','interrupted','cancelled')),
  stage TEXT NOT NULL CHECK(stage IN ('vision','text','lookup','local','done')),
  reference_time_json TEXT NOT NULL,
  context_json TEXT NOT NULL,
  queue_order INTEGER UNIQUE,
  reply_to_action_id TEXT,
  request_generation INTEGER NOT NULL DEFAULT 0,
  vision_summary_json TEXT,
  plan_json TEXT,
  receipt_json TEXT,
  error_code TEXT,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);
CREATE TABLE operation_actions (
  id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL REFERENCES operations(id),
  action_key TEXT NOT NULL,
  type TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN (
    'planned','waiting_input','waiting_confirmation','ready',
    'committed','failed','conflict','cancelled','undone')),
  payload_json TEXT,
  before_json TEXT,
  after_json TEXT,
  result_json TEXT,
  undo_of_action_id TEXT REFERENCES operation_actions(id),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE(operation_id, action_key)
);
CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY,
  operation_id TEXT REFERENCES operations(id) ON DELETE SET NULL,
  role TEXT NOT NULL CHECK(role IN ('user','assistant')),
  content_kind TEXT NOT NULL,
  body_text TEXT NOT NULL,
  delivery_status TEXT NOT NULL,
  image_count INTEGER NOT NULL DEFAULT 0 CHECK(image_count BETWEEN 0 AND 3),
  record_refs_json TEXT,
  quoted_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
  quote_snapshot_json TEXT,
  created_at_ms INTEGER NOT NULL,
  UNIQUE(operation_id, role)
);
CREATE TABLE chat_attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT REFERENCES chat_messages(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL UNIQUE,
  mime_type TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK(byte_length > 0),
  state TEXT NOT NULL CHECK(state IN ('pending','delete_pending')),
  created_at_ms INTEGER NOT NULL
);
CREATE TABLE meals (
  id TEXT PRIMARY KEY,
  origin_action_id TEXT NOT NULL REFERENCES operation_actions(id),
  client_ref TEXT NOT NULL,
  source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
  local_date TEXT NOT NULL,
  local_time TEXT,
  occurred_at_ms INTEGER,
  utc_offset_minutes INTEGER,
  meal_type TEXT NOT NULL CHECK(meal_type IN ('breakfast','lunch','dinner','other')),
  raw_description TEXT NOT NULL,
  note TEXT,
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  deleted_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE(origin_action_id, client_ref)
);
CREATE TABLE food_items (
  id TEXT PRIMARY KEY,
  meal_id TEXT NOT NULL REFERENCES meals(id),
  origin_action_id TEXT NOT NULL REFERENCES operation_actions(id),
  client_ref TEXT NOT NULL,
  name TEXT NOT NULL CHECK(length(trim(name)) > 0),
  portion_text TEXT,
  calories_kcal INTEGER CHECK(calories_kcal >= 0),
  protein_g REAL CHECK(protein_g >= 0),
  fat_g REAL CHECK(fat_g >= 0),
  carbs_g REAL CHECK(carbs_g >= 0),
  nutrition_sources_json TEXT NOT NULL,
  nutrition_basis_json TEXT NOT NULL,
  estimation_note TEXT,
  note TEXT,
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  deleted_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE(origin_action_id, client_ref)
);
CREATE TABLE weight_records (
  id TEXT PRIMARY KEY,
  origin_action_id TEXT NOT NULL REFERENCES operation_actions(id),
  client_ref TEXT NOT NULL,
  source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
  local_date TEXT NOT NULL,
  local_time TEXT,
  occurred_at_ms INTEGER,
  utc_offset_minutes INTEGER,
  input_value TEXT NOT NULL,
  input_unit TEXT NOT NULL CHECK(input_unit IN ('jin','kg')),
  grams INTEGER NOT NULL CHECK(grams > 0),
  raw_description TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  deleted_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE(origin_action_id, client_ref)
);
CREATE TABLE food_library (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('common_meal','packaged_food')),
  name TEXT NOT NULL,
  aliases_json TEXT NOT NULL,
  brand TEXT,
  variant TEXT,
  package_spec_json TEXT,
  base_portion_json TEXT NOT NULL,
  nutrition_json TEXT NOT NULL,
  source_json TEXT NOT NULL,
  consent_action_id TEXT NOT NULL REFERENCES operation_actions(id),
  version INTEGER NOT NULL DEFAULT 1,
  deleted_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);
CREATE TABLE ai_memories (
  id TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  content TEXT NOT NULL,
  consent_action_id TEXT NOT NULL REFERENCES operation_actions(id),
  version INTEGER NOT NULL DEFAULT 1,
  deleted_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);
CREATE TABLE consent_proposals (
  id TEXT PRIMARY KEY,
  operation_id TEXT REFERENCES operations(id),
  kind TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  target_id TEXT,
  expected_version INTEGER,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','accepted','rejected','expired')),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);
CREATE TABLE app_settings (key TEXT PRIMARY KEY, value_json TEXT NOT NULL);
CREATE INDEX idx_messages_time ON chat_messages(created_at_ms,id);
CREATE INDEX idx_actions_operation ON operation_actions(operation_id,status);
CREATE INDEX idx_meals_day ON meals(local_date,deleted_at_ms,meal_type);
CREATE INDEX idx_food_meal ON food_items(meal_id,deleted_at_ms);
CREATE INDEX idx_weight_day ON weight_records(local_date,deleted_at_ms,local_time);
CREATE INDEX idx_library_name ON food_library(name,deleted_at_ms);
CREATE INDEX idx_proposals_key ON consent_proposals(dedupe_key,status);
CREATE INDEX idx_attachment_state ON chat_attachments(state);
```

### 字段含义和删除关系

- context_json 保存明确日期 / 记录 ID / D02 引用对象，不保存图片、Key。quoted_message_id 和 quote_snapshot_json 为 D02 暂定字段。
- reply_to_action_id 在仓库边界校验指向待回答子操作；表间不循环外键。回答新消息仍有自己的 operation，通过该字段恢复原子事项，不重新创建已成功事项。
- record_refs_json 保存类型 / ID / action_id，界面重新读取当前值。历史卡片、旧回执不是当前事实。
- plan / payload 只存已校验数据提案。成功后可移除重复 payload，但 before / after / result 和去重 ID 保留，支持撤销。
- before / after 是该事项影响的全部实体快照，包括餐的元数据、食物、软删除状态和提交后的版本。一次撤销校验整个单位，不只校验其中一项。
- source_message 外键 SET NULL，删除聊天不影响记录；不删除操作账本。附件删除应先登记清理路径，再删消息，避免级联后丢失文件清理依据。
- 删除餐时同事务标记其有效食物删除；删末个食物同时标记空餐。普通列表、营养汇总、最近体重和日历点都过滤软删除。
- consent_action_id 是本地用户同意形成的 action，不由模型伪造。拒绝建议用规范化类型 / 目标 / 内容组合的 dedupe_key 去重，无需内容散列。

### 营养和资料 JSON

```json
{
  "nutrition_sources_json": {
    "calories_kcal":"user", "protein_g":"label",
    "fat_g":"ai", "carbs_g":"unknown"
  },
  "nutrition_basis_json": {
    "calories_kcal":{"note":"用户明确本次120 kcal"},
    "protein_g":{"base_amount":100,"base_unit":"ml","consumed_amount":250,"value_per_base":2.4},
    "fat_g":{"note":"按常见份量估算"},
    "carbs_g":null
  }
}
```

每个字段必须有来源；空值与 unknown 配套。热量依据可含 lower_kcal / upper_kcal，存在时验证非负、下界不大于上界且包含点估值。使用库时依据包含 library_id、library_version 和当时基准数值快照，不保留照片。食品库 base_portion 可为 `{amount:100,unit:"ml"}` 或常用餐食 `{amount:1,unit:"份",description:"普通外卖盒"}`；缺少换算关系时不能硬算。

## 6. 设置与查询

设置键：ai_profile（地址、四模型、HTTP 风险确认）、weight_unit、theme_mode（system / light / dark）、onboarding_completed、chat_draft（文字、附件 ID、定向对象）、privacy_notice_accepted。

Key 与规范化 Base URL 一起放安全存储。更换地址须重新确认 / 输入 Key，不能自动将旧 Key 发给新主机。模型列表为会话缓存，不是能力事实。

草稿附件先登记 message_id=NULL，发送事务再绑定并清理草稿引用。相册来源路径不长期保存。

日营养每字段分别 SUM，同时统计该字段 NULL 项数。食物必须同时满足自身和所属餐未删除。无行时汇总数值仅用于运算为 0，展示由食物数量和缺失数量决定。

```sql
SELECT COUNT(*) item_count,
       COALESCE(SUM(f.calories_kcal),0) known_calories_kcal,
       COALESCE(SUM(CASE WHEN f.calories_kcal IS NULL THEN 1 ELSE 0 END),0) pending_calories
FROM food_items f JOIN meals m ON m.id=f.meal_id
WHERE m.local_date=? AND m.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL;
```

蛋白质、脂肪、碳水同样计算，不能将餐与多条体重 JOIN 后求和。餐数为有效 breakfast / lunch / dinner 去重，其他事件另计。月历批量查月范围，不每天循环查询。

消息关键词搜索对 body_text 使用绑定参数并转义 LIKE 的 `% / _ / 反斜线`，每页 50 条，排序键 created_at_ms / id，可加载定位原消息周围内容。食品 / 记忆候选查询只返回相关有效条目。AI 查询目录见 04，不执行模型 SQL。

体重输入普通正十进制、最多两位小数，先转百分之一单位整数：132斤→13200×5=66000克；66公斤→6600×10=66000克。显示从克换算，去无意义尾零。

## 7. 事务和通知

一个完整子事项的实体变更、操作状态、前后快照、回执同事务提交。其他独立事项另行提交；共享一餐且互相依赖的修改先合成一个事项。不得在事务中发网络或弹确认框。

事务内只使用 sqflite transaction 对象，异常回滚这个单位，不吞错误继续“成功”。提交后通知旧 / 新日期与对象 ID，各 ViewModel 重读统一仓库。

恢复整库与清除数据有专用事务边界，见 05。schema 失败保留文件并提示，不删库重建；未来升级写明确迁移，不默认支持更高版本降级。
