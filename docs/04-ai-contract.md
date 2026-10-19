# 04 AI 接口与数据契约

## 1. 接入边界

V1 只支持 Responses API。用户提供的一组 Base URL / API Key 必须能调用 `POST /responses`；模型列表使用同一前缀下的 `GET /models`。模型角色为：

```text
text_primary     text_fallback
vision_primary   vision_fallback
```

文字、图片、模型检查和自动补算全部使用 Responses API，不增加协议选择器或自动切换接口。客户端自行提供必要上下文，显式设置 `store: false`，不依赖服务端会话、响应 ID 串联或远程历史。

业务输出采用提示词约定的 JSON 文本，客户端严格解析，不强制要求原生工具调用或 JSON Schema 输出能力。模型是否能稳定遵守协议仍需实际连接确认；拉到模型 ID 不等于其 Responses 调用和图片输入已经可用。

## 2. URL、鉴权与模型列表

### 2.1 Base URL 规则

用户填写接口前缀，例如 `https://example.invalid/v1` 或 `https://example.invalid/api/openai/v1`。

- 规范化只移除首尾空白与末尾 `/`，保留用户输入的路径前缀。
- 追加 `/models` 和 `/responses`，不擅自再加 `/v1`。
- 如果输入已经是完整 `/responses` 地址，提示改成接口前缀，不猜测其他路由。
- 不接受 URL 中的用户名、密码、query 或 fragment，避免凭据和路由含义混乱。
- 默认 HTTPS；HTTP 必须在设置页明确确认明文传输风险，仅对该完整配置生效。不得关闭 TLS 证书验证。
- 不自动跟随接口跨地址重定向，防止将 Authorization 发到未配置的主机。

### 2.2 请求头

使用 `Authorization: Bearer <设备安全存储中的Key>`；POST 使用 JSON。Key 不进入提示词、业务数据库、异常正文或导出文件。

### 2.3 模型列表

调用 `GET {base_url}/models`，从 `data` 数组读取字符串 `id`，去重、排序，供四个角色选择。官方模型列表只描述基本模型信息，不能据此推定所有候选都支持图片输入。[官方 OpenAI 模型列表契约](https://developers.openai.com/api/reference/resources/models/methods/list)

- 列表失败保留已有选择，显示原因并允许手输 ID。
- 不根据 ID 名字强行隐藏候选或自动分配文字 / 图片能力。
- 同类型主备 ID 必须不同；文字与图片可使用同一 ID。
- 不自动选第一个模型作为默认主模型。
- AI 设置未完成时不发请求，也不影响本地功能。

## 3. 每轮请求与主备规则

```text
纯文字 → text_primary → 失败 → text_fallback → 仍失败 → 提示失败
有图片 → vision_primary → 失败 → vision_fallback → 仍失败 → 提示失败
```

- 一条正常聊天最多两次模型调用，不做“先识图再调文字模型”的串联。
- 对应主模型只尝试一次、兜底只尝试一次；不用 `RetryClient` 或 SDK 内置的额外重试。
- HTTP 失败、超时、响应未完成、拒绝输出、空内容、JSON 无法解析、协议或引用不合法都属于模型请求失败。
- 图片主模型明确无法识别（`unrecognized`）也可尝试图片兜底；两个都不能识别时展示“无法识别，请补充文字或手动记录”，不编造结果。
- 有效的普通聊天、必要澄清、识别出非食物的说明都是正常结果，不为“没有新增记录”而换模型。
- 用户取消、输入配置不完整、本地数据库失败、记录版本冲突不是模型故障，不触发兜底。
- 主备使用同一份参考时间、原消息、图片和记录快照。兜底不是把主模型的错误回复当作新用户输入再聊一轮。
- 无论主备，最终业务写入只执行一次。主模型超时后迟到的结果必须被废弃。
- 排队中的下一条只在当前事项处理完成后开始；执行时重建快照，但沿用入队时固定的参考时间。后续排队消息不能提前混入当前请求上下文。

默认整次单模型请求截止时间：文字 90 秒，图片 120 秒；这些是客户端常量，不是服务承诺。取消或超时要中断底层请求，并用请求代次阻止迟到写入，不能只调用 `Future.timeout` 后继续接受回调。`http` 的可取消请求能力见 [维护者说明](https://pub.dev/packages/http)。

## 4. Responses 请求与响应

### 4.1 共用请求设置

调用 `POST {base_url}/responses`，使用 `model`、`instructions`、`input`，并显式设置 `stream: false`、`store: false`。不启用 background 模式，不携带 `previous_response_id` 或 `conversation`。每次请求独立构造本轮必要上下文，主备互不依赖服务端历史。[官方 Responses 文本生成说明](https://developers.openai.com/api/docs/guides/text)

V1 不强制指定 temperature、token 预算、推理档位或 tools。JSON 输出规则写在 instructions 中，最终仍由客户端执行完整校验；不增加按模型自动切换输出模式的分支。

`instructions` 包含固定规则、协议和带明确数据边界的本轮时间 / 记录快照；其中原描述仅作为引用数据，不能提升为系统指令。`input` 放近期本地对话与当前输入。重建的历史消息是独立上下文，不回传服务端 reasoning、工具结果或响应 ID。

### 4.2 文字请求

下面省略了实际 instructions 中的协议细节与近期对话，但字段结构可直接用于实现：

```json
{
  "model": "user-selected-text-model",
  "instructions": "按APP饮食记录协议理解输入，只输出一个JSON对象。",
  "store": false,
  "stream": false,
  "input": [
    {
      "role": "user",
      "content": [
        {"type": "input_text", "text": "中午吃了一碗牛肉面"}
      ]
    }
  ]
}
```

### 4.3 图片请求

当前 user content 使用一个 `input_text` 段加 1–3 个 `input_image` 段；每个图片段的 `image_url` 直接放 JPEG data URL 字符串，`detail` 为 `auto`。不调用文件上传接口、不使用远程 file_id 或自有图床。[官方图片输入说明](https://developers.openai.com/api/docs/guides/images-vision)

```json
{
  "model": "user-selected-vision-model",
  "instructions": "识别用户食物并按APP协议输出单个JSON对象。",
  "store": false,
  "stream": false,
  "input": [
    {
      "role": "user",
      "content": [
        {"type": "input_text", "text": "这是今天的午饭。"},
        {
          "type": "input_image",
          "image_url": "data:image/jpeg;base64,<本次压缩图片的Base64>",
          "detail": "auto"
        }
      ]
    }
  ]
}
```

示例中的 Base64 占位需要替换为真实编码。仅有图片时由客户端提供中性文字“请结合这些图片理解本条消息”，不把用户未表达的吃完、份数或餐别写成事实。

### 4.4 原始 HTTP 响应解析

1. 检查 HTTP 成功且顶层 `status` 为 `completed`；`failed / incomplete / cancelled / queued / in_progress` 不能作为本次同步请求的可提交结果。
2. 遍历 `output`，只取 `type = message`、`role = assistant` 且为已完成结果的消息。
3. 若有 `phase = commentary` 则不作为最终业务输出；取剩余已完成助手消息中的最后一条，将其 `type = output_text` 的 text 段按顺序组合成待解析文本。
4. `reasoning`、推理摘要和其他非文字项不当成回复；出现 `refusal`、未启用的工具调用或没有最终文本时按请求失败处理。
5. 对组合文本解析单个 JSON 对象，再执行第 6–8 节业务校验。不从残缺文本或多个 JSON 中挑一个执行。

原始 HTTP JSON 的文本位于 output 消息中；SDK 提供的聚合 `output_text` 便利属性不能当成所有服务都返回的顶层字段，也不能固定读取 `output[0]`。[官方输出解析说明](https://developers.openai.com/api/docs/guides/text)

响应示意：

```json
{
  "id": "resp_example",
  "status": "completed",
  "error": null,
  "output": [
    {"id": "rs_example", "type": "reasoning", "summary": []},
    {
      "id": "msg_example",
      "type": "message",
      "role": "assistant",
      "status": "completed",
      "content": [
        {
          "type": "output_text",
          "text": "{\"protocol_version\":1,\"outcome\":\"chat\",\"reply\":\"你好，今天吃了什么？\",\"image_summary\":null,\"candidates\":[],\"actions\":[]}",
          "annotations": []
        }
      ]
    }
  ]
}
```

响应 ID 只可用于当前诊断，不能替代客户端 operation_id 去重，也不成为长期会话依赖。服务端响应状态与本地 operations.status 是两套独立状态：模型 completed 不代表本地 committed。[Responses 状态定义](https://developers.openai.com/api/reference/go/resources/responses)

### 4.5 存储与取消

`store: false` 用于不依赖可检索的服务端响应存储；本地消息与记录仍保存。该参数不等于服务商承诺不保留任何运行日志，首次隐私说明仍按 05 执行。[官方数据处理说明](https://developers.openai.com/api/docs/guides/your-data)

取消使用当前 HTTP 请求的中断与本地请求代次保护。V1 不使用服务端后台任务、响应轮询、远程会话或远程取消工作流；服务端是否已停止计算由接口实现决定，客户端首先保证取消后不落库。

## 5. 上下文与历史定位

### 5.1 每轮提供什么

1. 系统行为规则、协议版本、本轮模式。
2. 固定的 `reference_local_datetime`、UTC 偏移、偏好体重单位。
3. 当前操作之前最近 12 条已处理的相关聊天消息，不包含后续排队输入、隐藏提示词、失败请求体、图片 Base64 或 Key。
4. 最近聊天卡片引用的记录当前值，以及最近 20 项食物、最近 10 次体重。
5. 当前输入明确提到的日期对应记录，每个日期最多 50 项，包含 ID、版本、日期、餐别、名称、份量、当前热量 / 体重。
6. 近期已保存的图片识别文字摘要。它们只是历史上下文，不能再次当成新发生的进食。

各集合按 ID 去重，删除的记录不作为可修改候选；达到上限时明确标记 `truncated: true`。不能声称已经看到了被截掉的数据。会话存储完整保留，不代表每次全量发送历史。

这些数量是客户端初始常量；因服务上下文限制而需要改变时，调整常量与实测依据，不增加用户要管理的“长期记忆”设置。

### 5.2 日期候选由本地准备

`ContextBuilder` 只需识别常见明确日期：今天、昨天、前天、`YYYY-MM-DD`、`YYYY年M月D日`、`M月D日`。缺年份按本轮年份；跨年语义不明确时澄清。

结合上一轮澄清的日期和候选 ID，执行参数化数据库查询。超出这个小范围的表达、目标未包含在候选中、历史同名项目过多时，让 AI 询问日期或让用户从日历选择，不让 AI 编造 ID。

V1 不让模型发 SQL，不增加工具调用循环，也不依赖整个聊天历史做模糊全文检索。最常见的“刚刚那碗面”由近期聊天引用的当前记录解决。

### 5.3 澄清后的下一条消息

- 澄清回复本身不写业务记录，该操作可提交为“仅澄清”的聊天结果。
- 下一条回答是新的操作 ID；提供上一轮未保存的原描述与问题，让模型整体理解后再提案。
- 回答操作关联 `reply_to_operation_id`，优先于原队列后续消息。原待确认饮食仍按原操作参考时间解释；回答本身的发送时间另外保留，不能把跨午夜的补充答案当成第二天新吃的一顿。
- 原输入已经有任何已提交记录时，快照明确提供其关联 ID，不能再次创建相同内容。
- 图片需要澄清份数等细节时，先保存足够的 `image_summary`；后续文字可依摘要继续，不需要长期保留照片。
- 已删除的照片不能重新查看细节。摘要不足以继续判断时，应请用户补充文字或重新选图。

## 6. 正常聊天响应协议

完整顶层结构：

```json
{
  "protocol_version": 1,
  "outcome": "chat",
  "reply": "告诉我吃了什么就好。",
  "image_summary": null,
  "candidates": [],
  "actions": []
}
```

| 字段 | 约定 |
| --- | --- |
| `protocol_version` | 必须等于 1 |
| `outcome` | `apply / chat / clarify / unrecognized` |
| `reply` | 简短自然语言；apply 时不作为保存成功回执 |
| `image_summary` | 文字请求为 null；图片正常处理结果为非空的可保留食物 / 场景描述，包含后续估算必要份量，不含“重新保存”指令；unrecognized 可为 null |
| `candidates` | 澄清用候选，元素为 `type` 和现有 `id`；非澄清时为空数组 |
| `actions` | apply 必须至少一项；其他 outcome 必须为空 |

输出必须是单个 JSON 对象，不包含 Markdown 围栏、前后解释或第二个对象。未知 outcome、操作类型或非法字段不按“差不多”执行。

普通聊天和澄清可展示 `reply`。`apply` 的成功文字和关联卡片由客户端提交结果生成；估算假设使用食物项的 `estimation_note`，不直接显示模型提前写出的“已保存”。

### 6.1 新增午餐示例

```json
{
  "protocol_version": 1,
  "outcome": "apply",
  "reply": "",
  "image_summary": null,
  "candidates": [],
  "actions": [
    {
      "type": "create_meal",
      "client_ref": "meal_1",
      "local_date": "2026-10-19",
      "local_time": null,
      "meal_type": "lunch",
      "raw_description": "中午吃了一碗牛肉面",
      "items": [
        {
          "client_ref": "food_1",
          "name": "牛肉面",
          "portion_text": "一碗",
          "calories_kcal": 580,
          "calorie_basis": "estimated",
          "estimation_note": "按普通餐馆一碗估算。"
        }
      ]
    }
  ]
}
```

客户端创建真实 ID、来源消息与操作关联、创建时间、版本，并换算已知时刻。`client_ref` 在本次操作中唯一，不能拿它当另一个历史记录的 ID。

### 6.2 纠正半个苹果示例

```json
{
  "protocol_version": 1,
  "outcome": "apply",
  "reply": "",
  "image_summary": null,
  "candidates": [],
  "actions": [
    {
      "type": "update_food",
      "id": "food-id-provided-in-context",
      "expected_version": 3,
      "patch": {
        "portion_text": "半个",
        "calories_kcal": 48,
        "calorie_basis": "estimated",
        "estimation_note": "按同一苹果的一半估算。"
      }
    }
  ]
}
```

只允许修改上下文中实际给出的 ID 和版本。份量改变时同时给出新热量，不能只改一项导致旧热量继续参与统计。客户端将 `estimated → ai`，`user_provided → user`；AI 不直接设置数据库来源或版本。

### 6.3 体重示例

```json
{
  "protocol_version": 1,
  "outcome": "apply",
  "reply": "",
  "image_summary": null,
  "candidates": [],
  "actions": [
    {
      "type": "create_weight",
      "client_ref": "weight_1",
      "local_date": "2026-10-19",
      "local_time": "08:10",
      "input_value": "132",
      "input_unit": "jin",
      "raw_description": "今天132斤"
    }
  ]
}
```

`08:10` 在本示例中来自固定的消息发送时间。统一克数由客户端计算，不能采用模型另报的换算值。

## 7. 动作目录

所有更新的 `patch` 必须非空；未出现的字段不修改，允许清空的字段用显式 null。模型不得修改 ID、创建操作、来源消息、创建时间或自行递增版本。

| type | 必需数据 | 允许效果 |
| --- | --- | --- |
| `create_meal` | `client_ref`、日期、可空时间、餐别、原描述、非空 `items` | 新建一餐及多个食物 |
| `add_food` | `meal_id`、`expected_meal_version`、一个 `item` | 向明确的已有餐新增食物 |
| `update_food` | 食物 `id`、`expected_version`、`patch` | 改名称、份量、热量与估算说明 |
| `update_meal` | 餐 `id`、`expected_version`、`patch` | 改本餐日期、时间、餐别；不替换整个食物数组 |
| `delete_food` | 食物 `id`、`expected_version` | 删除食物，最后一项删除时移除空餐 |
| `delete_meal` | 餐 `id`、`expected_version` | 删除整餐及所有食物 |
| `create_weight` | `client_ref`、日期、可空时间、数值文本、单位、原描述 | 新增一次测量 |
| `update_weight` | 体重 `id`、`expected_version`、`patch` | 改数值、单位、日期、时间 |
| `delete_weight` | 体重 `id`、`expected_version` | 删除一次测量 |

`item` 的结构与新增示例中的食物项一致。AI 新增 / 修改食物应给出可用的整数热量；若缺关键信息导致无法估算，返回 clarify。用户明确要求清空某项热量时，`update_food` 可将 `calories_kcal` 与 `calorie_basis` 同时设为 null，客户端存为 unknown。

允许的 patch 字段：

- `update_food`：`name`、`portion_text`、`calories_kcal`、`calorie_basis`、`estimation_note`。
- `update_meal`：`local_date`、`local_time`、`meal_type`。移到新日期且未明确时间时，`local_time` 设 null。
- `update_weight`：`input_value`、`input_unit`、`local_date`、`local_time`。改数值或单位后由客户端重新计算克数。

一次提案中可以创建多餐和体重。禁止对同一个现有实体提出两个相互覆盖的动作；需要改多个字段时合为一个 patch。涉及同一餐的多个新增 / 食物修改允许共同引用同一快照餐版本，由提交器先校验整个初始快照，再顺序执行，最后统一递增该餐版本。

## 8. 解析与执行边界

解析器在客户端外部边界检查：

1. JSON 完整性、顶层版本、枚举、字段类型与允许字段。
2. 非空食物名称、合法日期时间、非负整数热量、合法体重数值与单位。
3. 引用 ID 必须来自此次候选。意图判断由模型按系统规则完成；客户端不把图中文字视为用户命令，含图提案若要修改或删除既有记录，必须先让用户确认目标和变更。
4. apply 的有效动作至少一个、每餐至少一个食物，client_ref 不重复；chat / clarify / unrecognized 必须没有动作。
5. patch 中热量与来源成对，份量 / 食物变化时有一致的新热量。
6. 提案不含 SQL、文件路径、网络请求或任意代码。

提交前重新读取当前版本。版本变化或目标已删除属于冲突：不执行陈旧提案，不换模型赌一次，告诉用户记录已变化并允许重新发起。

用户输入和图片文字都是待理解内容，不能覆盖系统协议、绕过 ID 限制或要求泄露 Key。模型即使生成“已完成”，也不能改变客户端事务状态。

## 9. 自动补算协议

补算只走文字主备，不重新取照片。请求使用独立提示词，只提供本批次待估算食物的 ID、版本、当前名称、份量、必要备注和原餐描述，不发送无关聊天。

响应示例：

```json
{
  "protocol_version": 1,
  "outcome": "estimates",
  "estimates": [
    {
      "food_id": "pending-food-id",
      "expected_version": 2,
      "calories_kcal": 580,
      "estimation_note": "按常见一碗牛肉面估算。"
    },
    {
      "food_id": "another-pending-food-id",
      "expected_version": 1,
      "calories_kcal": null,
      "estimation_note": "食物名称不明确，请补充具体内容。"
    }
  ]
}
```

返回必须逐项覆盖请求 ID，每项一次，不得增加其他 ID。可给出 null 表示内容确实不足；此时保留待估算及简短原因。该有效结果不需要反复换模型。

补算只能设置热量、AI 估算说明和必要版本 / 更新时间，不允许改名称、份量、日期、餐别、用户备注或创建新食物。提交仍须满足当前值为 NULL 且版本匹配，详见 05。

## 10. 提示词维护

维护两份提示词模板：正常聊天、待估算补充。协议版本统一为 1，模板与解析器同步更新，不让四个模型各用一套业务规则。

正常模板必须包含：已进食才记、咨询计划不记、无克数可估、修改必须引用给定 ID、歧义先问、不要评价饮食、不要提前宣称保存成功、图片诚实识别、输出一个 JSON 对象。

不将助手性格写成冗长角色设定。产品语气按 01 执行；开发协作者的聊天角色不进入 APP 的系统提示词。
