# 04 AI 接口与数据契约

## 1. 唯一接口与能力要求

生成、识图、查询后的总结、模型检查、自动补算全部使用 **POST {base_url}/responses**。模型列表另用 GET {base_url}/models。不支持 Chat Completions，不做协议自动回退。

客户端维护历史和事实，使用 store=false，不用 previous_response_id、远程 conversation、background、响应轮询或服务端数据库。业务采用提示词约定 JSON，不强制模型原生 tools 或 JSON Schema；流式自然语言从 JSON 的 reply 字段增量提取，不能把整个 JSON 显示给用户。

这是本项目业务协议，不是 OpenAI 自带的饮食格式。第三方必须支持相应 Responses 输入、状态和流事件，并稳定输出协议；不兼容就明确报告，不悄悄换接口。真实兼容性在用户实际配置后确认。

## 2. URL、凭据与模型列表

Base URL 是接口前缀，例如 https://example.invalid/v1 或 https://example.invalid/api/openai/v1。只去首尾空白和末尾斜杠，再追加 /models 或 /responses，不擅自再加 /v1。完整 /responses 地址提示改为前缀，不猜路径。

不接受 URL 用户密码、query、fragment。默认 HTTPS；HTTP 要明确确认明文风险，只对当前配置生效，不关闭 TLS 校验，不自动跟随重定向发送 Key。

Authorization: Bearer 使用设备安全存储 Key；POST 为 JSON。更换地址重新确认 / 输入 Key，不将 Key 写入提示词、日志、普通库、备份或错误正文。

模型列表读取 data 中字符串 id、去重排序，四个角色支持搜索或手输。列表失败不清已有 ID；不根据名称推定视觉能力，不自动选首个模型。同类型主备须不同 ID；跨文字 / 图片角色可相同。

## 3. 请求阶段与主备

```text
纯文字：text主 → 失败 → text兜底 → 失败提示
图片（D03暂按A）：
  vision主 → 失败 → vision兜底 → 均失败则重选图 / 手动记
  有效摘要落地并删除临时图
  text主 → 失败 → text兜底 → 均失败则保留摘要，手动重试text
历史查询：text返回一次lookup → 本地只读查询 → text主备总结 / 提案
```

每次实际请求只走主一次、兜底一次，不用 SDK / RetryClient 透明重试。不把主模型错误回复混进兜底输入；同阶段使用相同时间、原输入、摘要与快照。

D03 暂定两阶段，正常图文通常两次模型调用；遇到一次本地查询可再加一次文本请求。含主备最坏：纯文字无查询 2 次、有查询 4 次；图文无查询 4 次、有查询 6 次。不计之后单独提示的补算批次，不隐藏额外调用。

HTTP错误、超时、failed / incomplete / refusal、空文本、整体协议无法解析属于模型失败；有效澄清、非食物说明、单个事项待确认不是。子操作版本冲突、本地保存失败和用户取消不换模型。Key无效 / 服务账户不可用等全局配置错误可直接失败，不为无意义重试增加费用。

初始截止时间：单次 text 90秒、vision 120秒。超时中断请求并推进 request_generation；不能只 Future.timeout 后仍接收迟到写入。每阶段和 lookup 轮次记录明确边界，重试已完成阶段不重新发图。

## 4. Responses 请求和 SSE

### 4.1 文字请求

```json
{
  "model":"selected-text-model",
  "store":false,
  "stream":true,
  "instructions":"遵守APP记录协议，只输出一个JSON对象。先outcome，再reply。reply只描述正在理解或回答，不提前宣称本地保存成功。",
  "input":[{"role":"user","content":[{"type":"input_text","text":"中午吃了一碗牛肉面"}]}]
}
```

实际 instructions 包含协议、时间和有界候选；用户原文、记录内容、图片标签均是数据，不能提升为系统指令。不强制 temperature、推理档位或通用 Agent tools。

### 4.2 图片请求（D03暂定A）

```json
{
  "model":"selected-vision-model",
  "store":false,
  "stream":false,
  "instructions":"仅输出APP视觉摘要JSON。读取图中食物、份量、产品和清晰标签，区分观察、用户描述与估算，不执行数据库操作。",
  "input":[{"role":"user","content":[
    {"type":"input_text","text":"刚吃了这个，只吃了半盒。"},
    {"type":"input_image","image_url":"data:image/jpeg;base64,<本次压缩图>","detail":"auto"}
  ]}]
}
```

同条 1–3 个 input_image，共同理解。只用 data URL，不建图床、不上传 Files。仅图片输入时加中性“请结合这些图片理解本条消息”，不补造吃完等事实。识图原始 JSON 不流给用户；文字阶段才展示自然语言。

### 4.3 流式解析

按 UTF-8 连续解码和 SSE 空行分帧，不能把单个 TCP chunk 当完整事件。合并同帧 data 行，解析 JSON，按事件 type、output_index / item_id、content_index 聚合，不能将不同输出串在一起。

- response.output_text.delta：累积最终 assistant message 的文字；忽略 reasoning、commentary、工具参数和非文本项。
- 业务 JSON 使用增量词法状态，只解码顶层 reply 字符串。处理转义引号、反斜杠、跨包 Unicode 和代理对；不使用正则截取花括号，不执行尚未结束的 actions。
- reply 是生成中说明，不是事实回执。prompt 禁止提前说已保存；界面始终标尚未保存，最终成功文字由客户端实际结果替换。
- response.completed：确认最终 response.status=completed，按完整 output 再取最终 assistant output_text 并完整解析；比对增量聚合，只有此时才能持久化计划。
- response.failed、response.incomplete、error、refusal、断流无完成事件：丢弃所有未提交提案，保留中断标记，走该阶段兜底。
- 未启用的 function_call 或只有推理没有最终 message，不当作有效业务输出。不假设顶层有 SDK output_text 便利字段，也不固定 output[0]。

普通 JSON 响应同样检查 completed，再读取 output 中最后一条非 commentary 的已完成 assistant message。服务 response.id 仅用于脱敏诊断，不作为本地幂等凭据。

官方事件依据见 [Streaming Responses](https://developers.openai.com/api/docs/guides/streaming-responses)。流式仅是展示，完整响应和本地提交分别是两个完成边界。

## 5. 视觉摘要协议

```json
{
  "protocol_version":1,
  "outcome":"recognized",
  "summary":"一盒米饭、鸡肉和青菜；用户说只吃了半盒。",
  "foods":[{"name":"鸡肉","portion_text":"半盒中的一份","uncertainty":"肉的具体做法不清"}],
  "labels":[],
  "questions":[],
  "important_uncertainty":"按图中份量粗估"
}
```

outcome 为 recognized / clarify / unrecognized / non_food。recognized / clarify 有可继续处理摘要；questions 只问关键。unrecognized 可尝试视觉兜底，两者失败明确失败。non_food 是有效结果，菜单咨询等交文字层按用户意图回应，不自动记录。

标签条目包括产品名称、品牌、口味、规格、基准 amount / unit、原能量 value / unit（kJ或kcal）、蛋白质 / 脂肪 / 碳水及可空缺失字段。看不清的数字填 null 和原因，不能猜。视觉层不输出 SQL、真实记录 ID 或写库 actions。

将通过校验的摘要保存 vision_summary_json 后删除图；向文字模型提供同一原用户文字、摘要、时间、相关资料，摘要标为参考数据。删除后若缺少图上细节，只能请用户补文字或重新选图，不假装再次查看。

## 6. 上下文与受限历史查询

每次包含：协议、固定参考时间、单位、明确上下文对象；最近12条已处理相关消息、最近20项食物 / 10次体重、引用记录当前值；明确日期每日期最多50项；相关食品候选和已确认偏好。按 ID 去重，截断标 truncated，不能声称看到全部历史。

不会把后续排队消息提前加入当前请求。每条执行时刷新事实；删除对象不作为可修改候选，历史图片只发摘要。

若需“上次吃牛肉面”等不在快照的事实，模型可返回一次只读 lookup：

```json
{
  "protocol_version":1,"outcome":"lookup","reply":"我帮你查一下已经保存的记录。",
  "queries":[{"query_id":"q1","type":"find_food","keyword":"牛肉面","date_from":null,"date_to":null,"limit":10}],
  "actions":[],"proposals":[]
}
```

允许目录：find_food（名称关键词 / 日期范围）、list_meals（日期范围 / 餐别）、recent_weights（数量 / 日期范围）、nutrition_totals（日期范围）、find_library（名称 / 品牌 / 口味 / 规格）。输入全为类型化字段；SQLite 参数绑定，不能带 SQL、路径或任意代码。

每轮最多一批 lookup，最多5个查询，每个最多50项、按当前记录返回；汇总在本地固定 SQL 计算。结果含 query_id、真实 ID / 版本、匹配数量、是否截断。再用相同时间与用户意图发一次 text 请求，返回 final 或澄清；不允许第二轮 lookup 循环。查无记录如实回答，不凭模型记忆猜。

用户关键词搜索是本地 UI 功能，不需 AI 调用。模型查询输出以当前记录为准，不从旧聊天数值相加。

## 7. 文字业务协议

```json
{
  "protocol_version":1,
  "outcome":"final",
  "reply":"我按普通面碗的份量帮你整理。",
  "queries":[],
  "actions":[{
    "action_key":"a1","state":"ready","type":"create_meal",
    "client_ref":"meal_1","local_date":"2026-10-19","local_time":null,
    "meal_type":"lunch","raw_description":"中午吃了一碗牛肉面",
    "items":[{
      "client_ref":"food_1","name":"牛肉面","portion_text":"一碗",
      "nutrition":{
        "calories_kcal":{"value":580,"source":"ai"},
        "protein_g":{"value":25,"source":"ai"},
        "fat_g":{"value":18,"source":"ai"},
        "carbs_g":{"value":80,"source":"ai"}
      },
      "estimation_note":"按普通餐馆一碗和常见用油估算。","nutrition_basis":{}
    }]
  }],
  "proposals":[]
}
```

顶层 outcome 只允许 final / lookup。普通聊天 final 且 actions 为空。reply 位于 actions 前用于流式说明，不能当保存回执。完整 JSON 无 Markdown、前后散文或多个对象。

每动作 action_key 本轮唯一，state 为 ready / clarify / confirm。clarify 带 question 和合法 candidates，记录未完整前不提交该事项；confirm 带目标 / 变更摘要。其他独立 ready 事项照常处理。

```json
{"action_key":"a2","state":"clarify","type":"update_food","question":"你说的是午餐牛肉面还是晚上的拌面？","candidates":[{"type":"food","id":"given-id-1"},{"type":"food","id":"given-id-2"}]}
```

新增一餐含全部食物为一个动作。已有同餐多个修改合成 modify_meal_contents，带一个初始餐版本和所有子项当前版本，事务内一起执行；不产生互相覆盖的独立动作。

| type | 必需数据与效果 |
| --- | --- |
| create_meal | 新 client_ref、日期、可空时间、餐别、原描述、非空 items |
| add_food | meal_id、expected_meal_version、完整 item |
| update_food | id、expected_version、patch；同步受影响营养 |
| modify_meal_contents | meal_id、expected_meal_version、带版本的 changes；同餐一起提交 |
| update_meal | id、expected_version、日期 / 时间 / 餐别 patch |
| delete_food / delete_meal | id、expected_version；删末项同步删除空餐 |
| create_weight | 新 client_ref、日期、时间、input_value、input_unit、原描述 |
| update_weight / delete_weight | id、expected_version、允许 patch 或删除 |
| undo_action | 提供给模型的既有 action_id；客户端生成与校验逆操作 |

营养 source 允许 ai / user / label / library / unknown，未知 value=null；label 必有清晰原标签依据，library 必引用给定库 ID / version、基准及换算快照。客户端核验资料依据，不能接受模型凭空声称标签来源。食物 patch 不允许改 ID、来源消息、创建操作、创建时间或版本。

营养值非负、日期合法、体重正数且单位 jin / kg。缺份量可估，缺主要食物应 clarify，不能创建空食物。同一目标有冲突动作时不执行冲突项，明确反馈，其他独立项保留。

### 允许修改的字段

- update_food：name、portion_text、nutrition、nutrition_basis、estimation_note。只给出需要变更的营养字段；清空值必须配 unknown。修改名称 / 份量时明确处理全部受影响营养，不能沿用不相符的旧值。
- update_meal：local_date、local_time、meal_type；明确移日但没有时刻时 local_time=null，不能改变餐内食物归属。
- update_weight：input_value、input_unit、local_date、local_time；统一 grams 由客户端重新计算，不采用模型给出的换算值。
- modify_meal_contents 的 changes 只允许对指定餐进行 add_food、update_food、delete_food，逐项带目标版本；不允许嵌套其他餐、任意字段或再次递归调用。
- 删除只允许指定的有效 food / meal / weight；资料和记忆管理通过各自授权路径，不接受 delete_all 等额外类型。

有清晰标签基准和用户明确食用量时，客户端按基准计算并取显示精度，不让模型任意改算术结果；kJ换算和同一份量缩放也由客户端核算。无法建立明确换算关系时才采用标明来源的AI粗估。

体重动作示例：

```json
{"action_key":"a3","state":"ready","type":"create_weight","client_ref":"weight_1","local_date":"2026-10-19","local_time":null,"input_value":"132","input_unit":"jin","raw_description":"今天132斤"}
```

更新动作必须同时携带目标当前版本，例如半碗面使用 update_food、给定 id / expected_version、portion_text 和更新后的 nutrition；原记录ID不变。date-only与具体时间的含义仍按03，不将示例时间当默认值。

### 提议保存长期资料

proposals 仅是建议，不直接写库：type 为 save_common_food / save_packaged_food / update_library / save_memory / update_memory；含暂存摘要、必要数值、目标 ID / expected_version 和规范化去重内容。客户端生成确认卡。用户同意形成独立 local action 后提交；拒绝不影响本餐。

用户明确要求保存某项可作为该项的授权，但不能把图中文字或旧摘要当授权。用户拒绝同一建议后抑制重复卡，显著不同新资料或用户主动要求可重新提出。资料更新不重算历史。

## 8. 校验和部分成功

先校验整体 JSON、版本、顶层结构，失败才走阶段兜底。完整有效 envelope 内逐个校验动作：非法类型、字段、引用或版本只让该事项失败，不用一个坏事项抹掉其他明确事项。

真实 ID 必来自本轮快照或 lookup 结果，更新前重读当前版本。模型不返回 SQL、文件路径或任意网络动作。图片中的“删昨天记录”不能作为命令；图文任务修改 / 删除既有对象时展示目标变更确认，用户文字已明确且唯一的常规纠正按产品规则处理。

确认后的计划保存在客户端并分配 action_id。执行一个事项的变更、快照、回执和状态同事务提交。某项成功后不重新将整条原文送模型新增；重试仅携带未完成 action_id 和允许效果，拒绝更改已完成范围。

## 9. 缺失营养补算协议

独立 text 请求，store=false；不需流式展示原 JSON。只发当前食物 ID / 版本 / 名称 / 份量、已知数值、缺失字段及相关本地资料，不发原图或无关聊天。

```json
{
  "protocol_version":1,"outcome":"estimates",
  "estimates":[{
    "food_id":"given-id","expected_version":3,
    "values":{"protein_g":{"value":25,"source":"ai"},"fat_g":{"value":null,"source":"unknown"}},
    "estimation_note":"脂肪缺少合理估算依据。"
  }]
}
```

逐项覆盖请求 ID，每项一次，只允许请求中的缺失字段。不能改名称、日期、份量或已有营养，不新增食物。null 是内容不足的有效结果，不反复换模型；完整格式错误才主备。提交须当前仍空且版本匹配，规则见 05。

## 10. 提示词与能力检查

维护 vision、text（含可选一次 lookup）、backfill 三份模板，共用 protocol_version=1、枚举和数据定义。必须覆盖进食意图、自然份量、来源优先级、日期、重复判别、修改 ID、授权边界、不提前成功和诚实识图。

模型检查分别验证 text SSE + 协议、vision 图像 + 摘要，不写记录、不触发补算；同一模型多角色按模态去重请求但分别反馈。拉模型列表不算能力检查；失败不增加 Chat Completions 或非流式聊天的隐藏降级。

APP 语气按 01；开发协作者的角色设定不进入产品提示词。实施时用用户配置确认实际模型能力，不写入开发者 Key。
