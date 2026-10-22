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
| 备份加密 | cryptography，pubspec.lock 锁定版本 | PBKDF2-HMAC-SHA256 派生、AES-256-GCM；不自写密码算法 |

最低 Android API 24。当前 Flutter 3.19.4、Dart 3.3.2、JDK 17、Gradle 8.2、AGP 8.2.2，compileSdk / targetSdk 34。依赖由 pubspec.lock 锁定，完整环境记录见 10。

不引入自有服务器、ORM / 代码生成、向量库、后台调度框架或通用 Agent SDK。历史关键词查询先用有界参数化 LIKE；小规模本地数据不需要搜索平台。

## 2. 模块与数据流

```text
页面 / ViewModel
 ├─ RecordRepository：本地记录、汇总、历史查询、版本
 ├─ ChatCoordinator：FIFO、定向回答、停止、阶段恢复
 │   ├─ ContextBuilder：参考时间、近期对话、对象、授权资料
 │   ├─ AiGateway：Responses、SSE、显式尝试与取消，次数按04的D10
 │   ├─ ProtocolParser：完整JSON、流式reply、字段与引用
 │   ├─ LocalLookup：受限只读查询，不接受SQL
 │   └─ ActionCommitter：独立子操作事务、回执、撤销
 ├─ LibraryRepository / MemoryRepository：确认资料和偏好
 ├─ BackfillCoordinator：只补缺失、让出用户消息
 ├─ ImageService：临时副本、摘要和清理
 ├─ BackupService：快照、CSV、加密、恢复
 └─ SettingsRepository：普通设置、安全凭据
```

职责不等于每项都要拆接口 / 实现类，普通具体类足够。记录、搜索与汇总共用 RecordRepository；协议校验并入 ContextBuilder，受限查询并入 RecordRepository，补算并入 ChatCoordinator，资料与记忆共用管理页。业务变更统一经过 ActionCommitter，AI 不生成或执行 SQL。

发送事务保存消息、operation、queue_order、参考时间、定向对象和附件归属。执行时刷新当前数据快照；vision 摘要持久化后转 text。文本返回完整提案，校验并保存子操作计划，然后逐个完整单位提交。实际提交后生成卡片，正常聊天成功且队列空闲时触发补算。

## 3. 工程目录

源码位于 app/，Android 工程位于 app/android/。

```text
app/lib/
  main.dart、app.dart
  core/（数据约定、建库、图片、主题、共享组件）
  records/（仓库、事务提交与撤销、卡片、编辑器）
  chat/（页面、协调器、Responses、上下文、提示词、确认预览）
  calendar/（月历、日详情、体重历史）
  library/（食品资料和授权偏好管理）
  settings/（接口、单位、外观）
  data_management/（CSV、备份、恢复和清除）
```

D01 直接编辑、D02 长按引用、D03 两阶段图片均已确认并实现。

### Android 桌面快捷入口

静态 shortcuts.xml 注册“记录体重 / 快速拍照录入”。ShortcutActivity 使用独立临时任务转发到原 MainActivity，避免静态快捷方式的清任务标志重建主页面；不改包名、签名或数据库。MainActivity 通过 `local.foodjournal.app/shortcuts` MethodChannel 暂存冷启动或 onNewIntent 的入口，Flutter 在引导完成后调用 takeShortcut 消费；重建状态保留已消费标记，拍照回来不重放入口。

JournalHome 串行消费入口，通过 NavigatorObserver 读取当前路由，并以 maybePop 保留现有表单退出确认，不强制丢弃修改。体重使用原 WeightEditor；拍照通过一次性 chatIntent 控制项调用原 ImageService，不把控制项存进 AI 上下文。ChatPage 等草稿加载后再拍照，打开相机前和照片返回后立即保存草稿；照片准备期间不允许重复选图或发送，返回后才聚焦输入，不自动发送。丢失照片恢复后优先回到聊天，食品资料照片仍与聊天恢复隔离。

## 4. 统一约定

- ID 为客户端 UUID。AI 新对象只给本次 `client_ref`，不能生成数据库真实 ID。
- `operation_id` 是一次用户提交；`action_id` 是其中一个可独立提交 / 重试 / 撤销的事项。模型的 action_key 仅在保存计划时映射一次，后续沿用客户端 ID。
- `version` 每次实体变化递增，撤销也不回退版本。删除采用软删除，以保留撤销和引用信息；普通查询一律排除 deleted_at_ms 非空行。
- 热量可空整数，营养素可空非负数；展示精度与存储原数值分开。每字段来源 `unknown / ai / user / label / library`，空值仅配 unknown。
- 当前食用量与资料库营养基准分开；历史食物保存已经换算的实际值和来源快照，不实时引用会变化的库值计算。
- 时间使用 local_date（发生日期权威）、local_time（HH:mm、中文时段或 null），另存 created_at_ms / updated_at_ms。支持的时段为凌晨、早上、上午、中午、下午、傍晚、晚上、深夜。只有 HH:mm 才计算 occurred_at_ms 和 utc_offset_minutes；时段或仅日期时两者为 null，不把时段换成精确发生时间戳。
- 今天未给时间的 AI 新增记录在 savePlan 时采用 operation 中固定的发送时刻并保存到计划，重试仍使用原值。历史日期无时间则保留 null；手动新增在表单打开时预填当前时间，手动清空与既有记录编辑不受 AI 默认规则影响。已有 null 时间不批量回填，展示时只显示日期。

## 5. SQLite schema 4

以下为 schema 4 沿用的原有表契约；新增运动表与原地迁移见第 8 节，由 core/database.dart 创建。schema 1 原地升级给 chat_messages 增加可空的 model_reply_text、receipt_text 和 reasoning_text；schema 2 升级只加 reasoning_text。保留旧 body_text 与全部业务记录，不回填旧思考。reasoning_text 独立于正文和搜索内容，普通历史与引用上下文均不发送该字段。启用 `PRAGMA foreign_keys = ON`，应用写入边界验证枚举、JSON 结构和数值配套。

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
  model_reply_text TEXT,
  receipt_text TEXT,
  reasoning_text TEXT,
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

- model_reply_text 保存已完整校验的自然回复，receipt_text 保存客户端最新状态；body_text 合并两者供复制、搜索和历史上下文使用。后续确认、澄清和撤销回执不覆盖自然回复，旧消息仍显示原 body_text。
- context_json 保存明确日期 / 记录 ID / 引用对象，不保存图片、Key。quoted_message_id 和 quote_snapshot_json 用于长按引用定位和源消息删除后的必要摘要。
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

每个字段必须有来源；空值与 unknown 配套。AI / 用户文字依据新写入时统一为 `{note:"说明"}`；此前已保存的字符串依据仍可在详情显示、编辑和备份恢复，无须清空记录。热量依据可含 lower_kcal / upper_kcal，存在时验证非负、下界不大于上界且包含点估值。使用库时依据包含 library_id、library_version 和当时基准数值快照，不保留照片。食品库 base_portion 可为 `{amount:100,unit:"ml"}` 或常用餐食 `{amount:1,unit:"份",description:"普通外卖盒"}`；缺少换算关系时不能硬算。

## 6. 设置与查询

设置键：ai_profile（地址、文字主模型、可选图片主模型与两个兜底、各角色的 role_effort、HTTP 风险确认）、weight_unit、theme_mode（system / light / dark）、onboarding_completed、chat_draft（文字、附件 ID、定向对象）、privacy_notice_accepted。角色强度键为 text_main_effort / text_backup_effort / vision_main_effort / vision_backup_effort；缺少该键即跟随服务端，旧配置仍可读取。

可选个人资料使用同一 app_settings 的 height_cm（大于 0、不超过 300 的有限数值或 null）与 sex（male / female / null）。无需新表或 schema 迁移，当前仍为 schema 4。SettingsRepository.bodyProfile 读取为 AI context.body_profile；设置页输入及备份导入共用校验，未设置保持 null，不虚构默认身高或性别。

发送范围沿用 operations.context_json，不新增表字段。聊天列表 / 搜索 / 原消息定位在读取时关联成 sent_context_json，作为界面范围标记；这个读取字段不写入数据库或备份表。引用快照仅附带日期、标签与目标表 / ID，不递归复制原引用链。AI 上下文提供 selected_date、带日期的完整日合计和历史消息所属日期，明细截断不截断合计。

Key 与规范化 Base URL 一起放安全存储。更换地址须重新确认 / 输入 Key，不能自动将旧 Key 发给新主机。模型列表为会话缓存，不是能力事实。

草稿附件先登记 message_id=NULL，发送事务再绑定并清理草稿引用。绑定的压缩副本保留为聊天预览，state=pending 表示仍可读取，不代表必须重新上传；是否重做识图取决于 vision_summary_json。摘要保存后不删附件，删除聊天或清空数据才清理。相册来源路径不长期保存。

食品表单使用独立library_editor_draft，保存表单字段、照片ID和识别草稿；library_photo_capture标记相机归属。启动恢复丢失的相机结果到该表单，并恢复添加页，不写入chat_draft或自动发起识别。清理孤立附件时保留该表单引用；保存 / 放弃后删除草稿与照片，整库恢复时清除旧表单草稿。食品备注保存在food_library.source_json.remarks，完整备份随资料保存，不需增加schema列。

日营养每字段分别 SUM，同时统计该字段 NULL 项数。食物必须同时满足自身和所属餐未删除。无行时汇总数值仅用于运算为 0，展示由食物数量和缺失数量决定。

```sql
SELECT COUNT(*) item_count,
       COALESCE(SUM(f.calories_kcal),0) known_calories_kcal,
       COALESCE(SUM(CASE WHEN f.calories_kcal IS NULL THEN 1 ELSE 0 END),0) pending_calories
FROM food_items f JOIN meals m ON m.id=f.meal_id
WHERE m.local_date=? AND m.deleted_at_ms IS NULL AND f.deleted_at_ms IS NULL;
```

蛋白质、脂肪、碳水同样计算，不能将餐与多条体重 JOIN 后求和。餐数为有效 breakfast / lunch / dinner 去重，其他事件另计。月历批量查月范围，不每天循环查询。

消息关键词搜索对 body_text 使用绑定参数并转义 LIKE 的 `% / _ / 反斜线`，每页 50 条，排序键 created_at_ms / id，可加载定位原消息周围内容。食品资料先提供全部有效条目的精简目录供语义判断，营养详情通过原有候选或 find_library.ids 获取；ID 列表限定 1–50 项，SQL 占位绑定，可与原关键词 / 品牌 / 口味 / 规格取交集。目录不带入库方式或时间排序权重，不新增分类字段、向量库或表结构。记忆仅提供已确认有效条目。AI 查询目录见 04，不执行模型 SQL。

体重输入普通正十进制、最多两位小数，先转百分之一单位整数：132斤→13200×5=66000克；66公斤→6600×10=66000克。显示从克换算，去无意义尾零。

## 7. 事务和通知

一个完整子事项的实体变更、操作状态、前后快照、回执同事务提交。其他独立事项另行提交；共享一餐且互相依赖的修改先合成一个事项。不得在事务中发网络或弹确认框。

事务内只使用 sqflite transaction 对象，异常回滚这个单位，不吞错误继续“成功”。提交后通知旧 / 新日期与对象 ID，各 ViewModel 重读统一仓库。

恢复整库与清除数据有专用事务边界，见 05。schema 失败保留文件并提示，不删库重建；未来升级写明确迁移，不默认支持更高版本降级。

## 8. 运动数据（R17）

schema 4 新增独立 exercise_records 及日期索引，不修改 meals / food_items / weight_records 的语义。低于 schema 4 时原地增表，新建库共用相同 SQL；不删除或重建旧表。

- 运动保存名称、原描述、发生日期 / 可空时间、可空 duration_minutes（分钟）、distance_meters（米）、intensity、calories_kcal、calories_source（unknown / user / ai）、calories_basis_json 与备注。未知不是 0，名称必填，时长有值时必须大于 0。
- 复用客户端 ID、来源消息、创建子操作、version、软删除和前后快照约定；运动不写入 meals 或 food_items，不占餐数，不改变饮食营养的含义。
- 时间沿用第 4 节的固定参考时间和时段规则，不把句子中的先后顺序换算成具体时刻；时长未知与实际为 0 分开。
- 日汇总分别读取饮食和运动，消耗另计已知值与缺失数；不能将多条运动与多条食物直接 JOIN 后相加造成重复。
- RecordRepository、ActionCommitter 和 BackupService 扩展承担查询、提交、撤销和备份。businessTables / entityTables 纳入运动，完整备份、安全副本、恢复和清除共用原有表顺序。
- AI 估算优先使用 `method=range_midpoint`：calories_basis_json 保存 lower_kcal、upper_kcal、note、duration_minutes 和可空 intensity。note 说明运动类型、参考信息与一般强度 / 成人体重等假设；假设不写成真实测量。客户端计算 round(lower_kcal / 2 + upper_kcal / 2)，保存、恢复时核对范围和中值。
- 有明确强度与真实适用体重时，仍支持原 MET 估算：读取运动日当天或此前最近体重，事务内核对 ID / version / grams；保存 note、met、weight_record_id、weight_version、weight_grams、weight_local_date、duration_minutes、intensity 与 method 快照。缺体重或强度不阻塞区间估算。后续称重不会重算运动，旧 MET 快照继续可读、撤销与恢复，schema 仍为 4。
- create_exercise 提交成功且有可选问题时，同事务创建独立 waiting_input 的 update_exercise，带已生成 ID 和当前版本；新增保持 committed。补充不是重做新增，版本不符或记录不存在时拒绝旧回答。

```sql
CREATE TABLE exercise_records (
 id TEXT PRIMARY KEY, origin_action_id TEXT NOT NULL REFERENCES operation_actions(id), client_ref TEXT NOT NULL,
 source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL, local_date TEXT NOT NULL,
 local_time TEXT, occurred_at_ms INTEGER, utc_offset_minutes INTEGER,
 name TEXT NOT NULL CHECK(length(trim(name))>0), duration_minutes REAL CHECK(duration_minutes>0),
 distance_meters REAL CHECK(distance_meters>=0), intensity TEXT,
 calories_kcal INTEGER CHECK(calories_kcal>=0), calories_source TEXT NOT NULL CHECK(calories_source IN ('unknown','user','ai')),
 calories_basis_json TEXT NOT NULL, raw_description TEXT NOT NULL, note TEXT,
 version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1), deleted_at_ms INTEGER,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, UNIQUE(origin_action_id,client_ref));
CREATE INDEX idx_exercise_day ON exercise_records(local_date,deleted_at_ms,local_time);
```
