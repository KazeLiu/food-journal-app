# 04 AI 接口与数据契约

## 1. 唯一接口与能力要求

生成、识图、查询后的总结、模型检查、自动补算全部使用 **POST {base_url}/responses**。模型列表另用 GET {base_url}/models。不支持 Chat Completions，不做协议自动回退。

客户端维护历史和事实，使用 store=false，不用 previous_response_id、远程 conversation、background、响应轮询或服务端数据库。业务采用提示词约定 JSON，不强制模型原生 tools 或 JSON Schema；流式自然语言从 JSON 的 reply 字段增量提取，不能把整个 JSON 显示给用户。

这是本项目业务协议，不是 OpenAI 自带的饮食格式。第三方必须支持相应 Responses 输入、状态和流事件，并稳定输出协议；不兼容就明确报告，不悄悄换接口。真实兼容性在用户实际配置后确认。

## 2. URL、凭据与模型列表

Base URL 是接口前缀，例如 https://example.invalid/v1 或 https://example.invalid/api/openai/v1。只去首尾空白和末尾斜杠，再追加 /models 或 /responses，不擅自再加 /v1。完整 /responses 地址提示改为前缀，不猜路径。

不接受 URL 用户密码、query、fragment。默认 HTTPS；HTTP 要明确确认明文风险，只对当前配置生效，不关闭 TLS 校验，不自动跟随重定向发送 Key。

Authorization: Bearer 使用设备安全存储 Key；POST 为 JSON。更换地址重新确认 / 输入 Key，不将 Key 写入提示词、日志、普通库、备份或错误正文。

模型列表读取 data 中字符串 id、去重排序，四个角色支持搜索或手输。只必填文字主模型；图片主模型按需配置，两个兜底可留空。列表失败不清已有 ID；不根据名称推定视觉能力，不自动选首个模型。已填写的同类型主备须不同 ID；跨文字 / 图片角色可相同。未配图片主模型时只限制识图入口，不限制纯文字和手动记录。

各角色独立配置思考强度：默认不发送 reasoning.effort；显式选择时发送，适用于聊天、识图、查询后总结、自动补算、食品表单识图与能力检查。可选 none / minimal / low / medium / high / xhigh / max，实际支持档位取决于模型和接口；不擅自更改选定档位或隐藏参数失败。另有可选 request_reasoning_summary，默认 false；为 true 时聊天各阶段及能力检查添加 reasoning.summary=auto，不给无展示入口的独立补算或食品表单识图额外请求摘要。参数支持由接口决定，按 [OpenAI 官方 reasoning 文档](https://developers.openai.com/api/docs/guides/reasoning) 接入。

## 3. 请求阶段与主备

```text
单阶段：主模型第1次 → 失败 → 主模型第2次
        → 仍失败且已配备用 → 备用第1次 → 失败 → 备用第2次
        → 仍失败则提示失败；任一次成功即结束本阶段
图片（D03已确认A）：
  vision按上述顺序尝试 → 全部失败则重选图 / 手动记
  有效摘要落地，压缩预览随聊天保留
  text按上述顺序尝试 → 全部失败则保留摘要，手动重试text
历史查询：text返回一次lookup → 本地只读查询 → text按同一规则总结 / 提案
```

**D10：所有模型首次调用失败后，必须在同一模型上重试一次。** 主模型累计两次失败后才切换已配置的备用模型，备用首次失败后也重试一次。没有备用时主模型两次失败即结束；任一次成功就立即继续，不为凑次数额外请求，也不重复已完成阶段。

此规则覆盖文字聊天、图片识别、查询后总结、自动补算、食品资料表单识图和模型能力检查。能力检查逐个检查已填写模型，每个模型失败后也重试一次，分别报告结果，不用备用成功冒充主模型成功。模型列表 GET /models 不属于模型生成调用，不套用主备顺序。

重试由应用层显式执行，不叠加 SDK / RetryClient 透明重试。同一阶段保持参考时间、原输入、摘要与快照不变；同一模型重试保持其思考强度等参数，切换备用才采用备用配置。不把失败回复混进下一次输入。

聊天整体结构校验失败时，可在剩余尝试的 instructions 中附加客户端给出的具体字段错误，要求重新输出完整协议；原任务 input、所选模型参数和调用上限不变。不回传失败的原始回复，不用默认动作补齐缺失的 action_key / type / state 后写库。

D03 正常图文仍通常为识图、文字各一次；lookup 可再增加一次文字阶段。各阶段均配置备用且用满尝试次数时，上限为：纯文字无查询 **4 次**、有查询 **8 次**；图文无查询 **8 次**、有查询 **12 次**。每个阶段未配备用时最多 2 次，已配备用时最多 4 次。单批补算或单次食品资料识图同样最多 4 次；独立补算批次和用户手动重试另计，不隐藏额外调用。

HTTP错误（包括接口返回的授权 / 服务账户错误）、超时、failed / incomplete / refusal、空文本、整体协议无法解析均按上述顺序重试；最终失败保留明确原因。发送前缺少必要配置则不请求。有效澄清、非食物说明、未知营养或单个事项待确认不是模型调用失败，不据此重试。子操作版本冲突、本地保存失败和用户取消不触发模型重试或切换；停止、数据替换和清除后不再发下一次尝试。

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

### 4.2 图片请求

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

图片请求可带本机发送进度回调。按UTF-8 JSON请求体（含Base64图片与上下文）的总字节分块发送，每块交给传输层后报告累计值；不记录正文或Key。依据 [Dart IOSink.flush](https://api.dart.dev/dart-io/IOSink/flush.html)，这不是远端收件确认。最后一块发完后切换识别等待预估；单次截止从请求开始计算，取消仍关闭原传输，不增加模型尝试次数。

食品资料表单的拍照入口单独使用同一组 vision 主 / 兜底，每个模型首次失败后重试一次，主模型两次失败才切换已配置的兜底，单次 120 秒，store=false、stream=false。同一请求只发送本次同一食品的1至3张照片，不发送聊天、记忆或资料库，不接续文字模型，不询问是否吃过或喝过。输出 protocol_version=1 的表单草稿字段：outcome、kind、name、aliases、brand、variant、package_spec、base_amount、base_unit、portion_description、energy_value、energy_unit、protein_g、fat_g、carbs_g、note。aliases为字符串数组，允许联想常用简称；客户端去空白、去重并去除正式名称，缺失或null按空数组，非法类型拒绝。note综合可读的配料表、过敏原、储存说明及看不清部分，客户端映射为可编辑remarks，保存于source_json.remarks。包装标签未知值留空，客户端校验类型 / 非负值、基准与能量单位，并换算 kJ / 4.184；缺少完整基准不填营养值。普通餐食的估算标记为 ai，包装标签保留原能量与基准。有效非食品 / 多食品不换兜底；只有人工点击保存才执行本地资料写入，停止时丢弃迟到结果。

### 4.3 流式解析

按 UTF-8 连续解码和 SSE 空行分帧，不能把单个 TCP chunk 当完整事件。合并同帧 data 行，解析 JSON，按事件 type、output_index / item_id、content_index 聚合，不能将不同输出串在一起。

- response.output_text.delta：只累积最终 assistant message 的文字，不混入 reasoning、commentary、工具参数和非文本项。
- 思考单独接收 response.reasoning_summary_text.delta / done、response.reasoning_text.delta / done，以及 reasoning output_item 中公开的 summary / content。按 item 和 summary_index / content_index 合并，done 替换对应增量而不重复追加；同时有摘要与 reasoning_text 时优先展示摘要。不请求或解析 encrypted_content，不从正文截取伪造 think。
- onReasoning 独立驱动灰色小号斜体区域，正文开始即折叠。成功阶段的思考单独保存在 reasoning_text；失败后新尝试替换当前思考，不拼接不同尝试；停止时保留已收到的部分。思考不进入业务 JSON、正文搜索或后续历史 / 引用上下文。
- 业务 JSON 使用增量词法状态，只解码顶层 reply 字符串。处理转义引号、反斜杠、跨包 Unicode 和代理对；不使用正则截取花括号，不执行尚未结束的 actions。
- reply 是生成中说明，不是事实回执。prompt 禁止提前说已保存；生成时标尚未保存，完整回复与客户端保存状态分开保留，卡片根据实际结果展示。
- response.completed：收到事件即停止读取，不再等待连接关闭；确认最终 response.status=completed，按完整 output 再取最终 assistant output_text 并完整解析、比对增量聚合，只有通过校验才能持久化计划。完整完成后不因服务端保持长连接再超时切兜底。
- response.failed、response.incomplete、error、refusal、断流无完成事件：丢弃所有未提交提案，保留中断标记；先重试当前模型一次，用满两次才切换已配置的备用模型，备用同样最多两次。
- 未启用的 function_call 或只有推理没有最终 message，不当作有效业务输出。不假设顶层有 SDK output_text 便利字段，也不固定 output[0]。

普通 JSON 响应同样检查 completed，再读取 output 中最后一条非 commentary 的已完成 assistant message。服务 response.id 仅用于脱敏诊断，不作为本地幂等凭据。

官方事件依据见 [Streaming Responses](https://developers.openai.com/api/docs/guides/streaming-responses) 和 [Responses 流式事件](https://developers.openai.com/api/reference/resources/responses/streaming-events)。流式仅是展示，完整响应和本地提交分别是两个完成边界。

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

outcome 为 recognized / clarify / unrecognized / non_food。recognized / clarify 有可继续处理摘要；questions 只问关键。unrecognized 按识图失败执行主模型两次、已配备用两次的尝试顺序，全部失败明确提示。non_food 是有效结果，不据此重试，菜单咨询等交文字层按用户意图回应，不自动记录。

labels 每条固定字段为 product_name、brand、variant、package_spec、base_amount、base_unit、energy_value、energy_unit（kJ / kcal）、protein_g、fat_g、carbs_g、reason。package_spec 为 {amount,unit,count,description} 或 null；数字、单位看不清则填 null 和原因，不能猜。视觉层不输出 SQL、真实记录 ID 或写库 actions。

将通过校验的摘要保存 vision_summary_json，保留压缩图仅供用户预览；向文字模型提供同一原用户文字、摘要、时间、相关资料，摘要标为参考数据。定向回答若补新图，保留 previous_summary 以继续使用此前标签证据；没有新图时直接复用摘要。文字模型不能直接查看本地预览，摘要缺少细节时请用户补文字或重新选图，不假装再次查看。

## 6. 上下文与受限历史查询

### 当前实现

每次包含：协议、固定参考时间、单位、明确上下文对象；最近12条消息、最近20项食物 / 10次体重、引用记录当前值；当前目标日期最多50项食物及该日汇总；相关食品候选和已确认偏好。近期消息和记录可跨日。按 ID 去重，截断标 truncated，不能声称看到全部历史。

食品候选匹配名称、别名和品牌，最多10项，顺序为定向条目、精确名称、别名、品牌候选；library_match 标明匹配方式。同品牌不代表同产品，产品身份未明确时先查 find_library 或追问。改食品名、重新计算时先核对给定库资料，不直接绕过资料库估算。

recent_image_summaries 最多提供3条已经持久化的识图摘要，含原图片消息 message_id；显式引用的图片优先。不发旧图字节，不用普通聊天估算代替标签原值。用户在后续消息要求保存标签或补规格时，模型可在资料建议上提供 label_message_id，客户端只接受本次给定摘要中的 ID；未指定 ID 时只采用唯一产品名称或品牌加口味匹配，歧义则拒绝。

selected_date 是本句未明确其他日期时的默认范围，日历所选日优先于发送日；selected_day_totals 附同一 local_date，来自该日完整本地汇总，不受50项明细上限影响。历史消息附 sent_date 和 selected_date，其“今天”不作为本次日期。针对具体记录 / 引用对象时优先围绕该对象，问整天才用日合计；用户明确其他日期则 lookup 对应范围。引用消息在未另选日期时沿用原日期，新日期上下文优先。

不会把后续排队消息提前加入当前请求。每条执行时刷新事实；删除对象不作为可修改候选，历史图片只发摘要。完整实体按 ID 统一放在 records_by_id，其他位置用 ref_id 引用，避免一份实体重复传输；查询结果归入同一注册表。

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

### 按日上下文调整（D09，待开发）

用户已明确默认只提供发送当天的全部有效业务记录；引用特定日期时改用该日期，比较时提供所有涉及日期。数据包含饮食、食物明细、已知营养和全部体重，运动实现后纳入各次运动。此设计替代默认跨日近期记录快照，当前源码仍采用上方“当前实现”。

推荐复用现有 lookup 路径，不增加独立的意图分类模型：

1. 客户端按固定参考日期或明确的定向日期读取完整日记录与本地汇总，连同当前输入发送给文字模型。
2. 若已能回答或提出操作，模型直接返回 final；普通文字处理一次请求即可完成。
3. 若需要其他日期，模型在这次正常请求中返回结构化 lookup。客户端校验并读取相关日期，再携带原问题、原日数据和补充数据请求文字模型生成 final。不是由模型直接访问数据库。
4. 例如“和昨天比，我今天吃得多了还是少了”：首次提供今天，模型请求昨天，客户端补入昨天后第二次回答；两天的营养合计在本地计算，缺失或没有记录需说明。

上述次数指正常成功的纯文字流程，不含已有的识图阶段、主备失败和独立补算。无需查询时不追加请求；已知目标日期可在第一次请求前本地读取，明确日期关键词预读可作为后续优化，不作为当前必须建设的额外层。

完整日数据不能继续直接套用“最多 50 项”后声称完整。开发前需明确单日读取、批量日期查询与总上下文预算的配合；数据过大时应报告范围和缺失，不能静默裁掉食物、运动或体重后仍给完整比较。当天聊天原文和长期记忆如何筛选仍待确认，与日记录完整性分开处理。

## 7. 文字业务协议

local_time 为 HH:mm、凌晨 / 早上 / 上午 / 中午 / 下午 / 傍晚 / 晚上 / 深夜，或 null。今天新增且未给时间时采用固定参考发送时刻，客户端在保存计划时补齐空值；历史日期没有时间时保留 null。明确时段直接保存中文时段，不补造具体时刻；明确 HH:mm 则保留该时刻。旧记录不因重试或编辑被自动改成当前时间。

```json
{
  "protocol_version":1,
  "outcome":"final",
  "reply":"我按普通面碗的份量帮你整理。",
  "queries":[],
  "actions":[{
    "action_key":"a1","state":"ready","type":"create_meal",
    "client_ref":"meal_1","local_date":"2026-10-19","local_time":"中午",
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

营养 source 允许 ai / user / label / library / unknown，未知 value=null。nutrition_basis 的 AI / 用户说明使用 `{note:"简短依据"}`，客户端也将文字形式规范为 note 对象；label 必有清晰原标签依据，library 必引用给定库 ID / version、基准及换算快照。客户端核验资料依据，不能接受模型凭空声称标签来源。食物 patch 不允许改 ID、来源消息、创建操作、创建时间或版本。

已保存资料的 source_json.type=label 表示过去的标签依据，复用时食物营养 source 必须为 library。若模型误写 label，只有提供的库候选中唯一精确名称 / 别名匹配、食用量有效且单位一致时才规范成 library，并由提交器读取库原值计算；品牌匹配、多个同名候选或不兼容单位不能这样转换。毫升 / ml、克 / g 视为同单位，不据此把盒换成毫升或把克换成毫升。

营养值非负、日期合法、体重正数且单位 jin / kg。缺份量可估，缺主要食物应 clarify，不能创建空食物。同一目标有冲突动作时不执行冲突项，明确反馈，其他独立项保留。

### 允许修改的字段

- update_food：name、portion_text、nutrition、nutrition_basis、estimation_note。只给出需要变更的营养字段；清空值必须配 unknown。修改名称 / 份量时明确处理全部受影响营养，不能沿用不相符的旧值。
- update_meal：local_date、local_time、meal_type；明确移日但没有时刻时 local_time=null，不能改变餐内食物归属。
- update_weight：input_value、input_unit、local_date、local_time；统一 grams 由客户端重新计算，不采用模型给出的换算值。
- modify_meal_contents 的 changes 只允许对指定餐进行 add_food、update_food、delete_food，逐项带目标版本；不允许嵌套其他餐、任意字段或再次递归调用。
- 删除只允许指定的有效 food / meal / weight；资料和记忆管理通过各自授权路径，不接受 delete_all 等额外类型。

有清晰标签基准和用户明确食用量时，客户端按基准计算并取显示精度，不让模型任意改算术结果；kJ换算和同一份量缩放也由客户端核算。无法建立明确换算关系时才采用标明来源的AI粗估。

体重动作示例（参考发送时间为 2026-10-19 08:45）：

```json
{"action_key":"a3","state":"ready","type":"create_weight","client_ref":"weight_1","local_date":"2026-10-19","local_time":"08:45","input_value":"132","input_unit":"jin","raw_description":"今天132斤"}
```

更新动作必须同时携带目标当前版本，例如半碗面使用 update_food、给定 id / expected_version、portion_text 和更新后的 nutrition；原记录ID不变。仅日期、时段与具体时间的含义按03，不将示例时间当固定默认值。

### 提议保存长期资料

proposals 仅是建议，不直接写库：type 为 save_common_food / save_packaged_food / update_library / save_memory / update_memory；含暂存摘要、必要数值、目标 ID / expected_version 和规范化去重内容。客户端生成确认卡。用户同意形成独立 local action 后提交；拒绝不影响本餐。

食品建议的aliases允许模型联想常用简称、俗称；更新时保留仍适用的原别名，不混入其他品牌或口味。泛称匹配多项时仍需确认身份，不因此跳过产品与营养依据校验。

包装资料建议可通过 label_message_id 继续使用先前图片的真实标签，客户端按原摘要覆盖模型复制的营养与基准并记录来源消息。每100毫升的营养基准和整罐330毫升规格分别保存，标签0值保留为0。建议保存失败时显示可操作的具体原因，回执不重复追加自然回复。

用户明确要求保存某项可作为该项的授权，但不能把图中文字或旧摘要当授权。用户拒绝同一建议后抑制重复卡，显著不同新资料或用户主动要求可重新提出。资料更新不重算历史。

## 8. 校验和部分成功

先校验整体 JSON、版本、顶层结构，失败时按第 3 节在当前模型重试，用满两次才切换已配置的备用模型。完整有效 envelope 内逐个校验动作：非法类型、字段、引用或版本只让该事项失败，不用一个坏事项抹掉其他明确事项，也不因此重试整个模型请求。

真实 ID 必来自本轮快照或 lookup 结果，更新前重读当前版本。模型不返回 SQL、文件路径或任意网络动作。图片中的“删昨天记录”不能作为命令；图文任务修改 / 删除既有对象时展示目标变更确认，用户文字已明确且唯一的常规纠正按产品规则处理。

确认后的计划保存在客户端并分配 action_id。执行一个事项的变更、快照、回执和状态同事务提交。某项成功后不重新将整条原文送模型新增；重试仅携带未完成 action_id 和允许效果，拒绝更改已完成范围。非法事项不保留可执行 payload，只保留错误及非执行 scope；retry_scope 描述待处理范围，retry_current_records 提供当前值，completed_scope 标明已处理或取消事项，防止重复新增。

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

逐项覆盖请求 ID，每项一次，只允许请求中的缺失字段。可复用本次提供的已确认食品资料，source=library，并在 nutrition_basis 对应字段提供库 ID / version、基准与食用量；客户端读取库原数值进行换算。其他估算 source=ai，无法合理估算填 null / unknown。不能改名称、日期、份量或已有营养，不新增食物。null 是内容不足的有效结果，不因此重试或切换模型；调用失败或完整格式错误时才按 D10 执行有界尝试。提交须当前仍空且版本匹配，规则见 05。

## 10. 提示词与能力检查

维护 vision、text（含可选一次 lookup）、backfill 三份模板，共用 protocol_version=1、枚举和数据定义。必须覆盖进食意图、自然份量、来源优先级、日期、重复判别、修改 ID、授权边界、不提前成功和诚实识图。

模型检查分别验证 text SSE + 协议、vision 图像 + 摘要，不写记录、不触发补算；同一模型多角色按模态去重请求但分别反馈。每个受检模型首次失败后重试一次，成功即结束该检查，两次失败才报告失败；不以另一个模型的成功覆盖其结果。拉模型列表不算能力检查；失败不增加 Chat Completions 或非流式聊天的隐藏降级。

APP 语气按 01；开发协作者的角色设定不进入产品提示词。实施时用用户配置确认实际模型能力，不写入开发者 Key。

## 11. 运动业务扩展草案（R17，待确认）

本节描述后续扩展方向，当前 protocol_version=1 的动作与查询目录不因此增加新类型。最终字段、动作格式与协议版本在 [09](09-decisions-to-confirm.md#运动记录扩展r17) 的细节确认后制定。

- 同一条文字输入可提出多个饮食动作和独立运动动作，分别反馈；“准备运动”或咨询不等于已完成运动。
- 建议支持运动新增、修改、删除、逐项撤销和有界历史查询；修改必须定位真实 ID 与当前版本，不能按运动名称覆盖所有同名记录。
- 推荐允许只保存运动名称，其余信息未知时留空。若采用“先保存再追问”，补充回答应更新已提交记录，不能把原新增动作重新置为待提交；关联运动 ID、当前版本和待补内容的具体方式在开发前明确。
- 不足以估算消耗时不编造数值；用户明确提供的消耗与 AI 估算区分来源，所用参数和依据随记录保存。体重和估算口径按 D07 确认。
- 混合消息中运动待补充或失败时，明确的独立饮食项仍可保存；后续仅处理未完成范围，不重记已保存食物或运动。
- 运动查询结果单独返回有效记录和消耗汇总，不混入 nutrition_totals。现有食品营养补算协议不直接用于运动；是否补算运动消耗随 D07 确认。
