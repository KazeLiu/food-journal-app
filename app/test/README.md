# 重点测试与运行方式

优先检查资料库名称 / 别名匹配、标签与库来源换算、后续消息保存先前标签，以及 think 流式 / 折叠 / 停止 / 持久化；主主备备的有界重试、日期引用、主页滚动和数据恢复仍保留。不需要手机、模拟器或真实 AI 凭据。

在 app/ 目录执行：

```powershell
flutter pub get
flutter test test/chat/context_builder_test.dart test/chat/chat_coordinator_test.dart test/chat/ai_gateway_test.dart test/chat/chat_scroll_test.dart test/ui_regressions_test.dart test/core/database_test.dart test/data_management/backup_service_test.dart --reporter expanded
flutter test test/settings/ai_settings_page_test.dart test/settings/settings_repository_test.dart test/chat/ai_gateway_test.dart --reporter expanded
flutter test test/library/food_photo_test.dart --reporter expanded
flutter test test/core/data_test.dart test/records/action_committer_test.dart test/records/record_flows_test.dart test/data_management/backup_service_test.dart --reporter expanded
flutter test test/chat/vision_progress_test.dart test/chat/chat_scroll_test.dart test/chat/chat_coordinator_test.dart --reporter expanded
flutter test test/ui_regressions_test.dart test/chat/ai_gateway_test.dart test/chat/chat_coordinator_test.dart test/core/image_service_test.dart test/core/database_test.dart test/data_management/backup_service_test.dart --reporter expanded
```

运行当前全部单元与 Widget 用例：

```powershell
flutter test --reporter expanded
```

项目使用 Flutter 3.19.4 / Dart 3.3.2，测试框架为 Flutter SDK 自带的 flutter_test。数据库用例通过生产建库入口、真实 SQLite 和生产提交器执行，不用模拟 SQL 返回值代替事务。测试专用依赖 sqflite_common_ffi 2.3.3、path_provider_platform_interface 2.1.2 由 pubspec.lock 锁定，不加入 Android 运行时依赖。本轮仅编写并静态检查，未执行测试；通过 / 失败结果以你后续实际运行为准。

数据库测试的 Windows SQLite DLL 随 ffi 包提供；Linux 环境需可用的系统 libsqlite3，详见 [sqflite_common_ffi 2.3.3 官方说明](https://pub.dev/packages/sqflite_common_ffi/versions/2.3.3)。

## 覆盖范围

| 文件 | 重点行为 |
| --- | --- |
| chat/chat_scroll_test.dart | 标题栏精简、320 / 430 / 1000dp 下按钮等宽居中限宽、识图与文字阶段切换；今日概览置顶 / 统计更新 / 日历入口、键盘下输入与聊天可用；鼠标滚轮近底部上翻、拖拽与异步刷新竞争、分页位置 / 连点、卡片离屏保留展开状态、读历史时新消息不抢位置、流式内容变长与恢复底部跟随 |
| chat/vision_progress_test.dart | 两分钟减速曲线、95%上限、原起点恢复、长等待文案、新请求重置与计时器清理 |
| library/food_photo_test.dart | 食品标签基准 / kJ换算 / 未知与0、非法响应、主备仅图片模型、取消请求；实际表单拍照填写不自动入库、人工保存、无配置仍可手填、重拍确认 / 取消、相机取消 / 拒绝后的恢复、临时图清理、食品与聊天拍照的进程恢复分离 |
| records/record_card_test.dart | 本次 String / Map 依据回归、四营养、结构化换算依据、热量区间、真实零值与缺失值 |
| records/record_flows_test.dart | 手动饮食 / 体重默认当前时间、主动清空、编辑保留时段和时间选择器；实际详情入口读取旧记录、展开与直接编辑；空名称提示后可继续保存、退出确认、多食物删除、身份变化清营养、体重切换精度与保存退出 |
| records/action_committer_test.dart | 今天缺时刻默认发送时间且重试不变、历史日期 / 时段 / 明确时刻保留；整餐事务与回滚、同一 action 幂等、部分成功、版本冲突、具体事项撤销、末项删除与恢复、重试保护、文字依据规范化、只补空值、库基准换算、长期资料确认与拒绝去重 |
| ui_regressions_test.dart | 实际记忆页居中、展开食物左边界一致、聊天回复 / 回执 / 卡片共存、80dp缩略图点击大图与返回、旧版缺图提示；think 增量更新、正文开始自动折叠、手动展开与灰色13px斜体 |
| records/record_repository_test.dart | 上午 / 中午 / 下午顺序；自然回复不被状态更新覆盖且可搜索；同日多次记录、餐数与月历点、入队失败保留草稿、快捷分析不消费草稿、特殊字符搜索、同毫秒分页、删聊天保留记录、重启恢复占用状态 |
| chat/ai_gateway_test.dart | 本机真实 HTTP / SSE：模型列表、UTF-8 / CRLF、completed 校验、完成后不等连接关闭、断流 / 拒绝 / 不完整、流式与最终文本不一致、401、拒绝跟随重定向、取消和超时 |
| chat/chat_coordinator_test.dart | 主主备备顺序、成功即停、协议 / 授权失败重试、无备用最多两次、补算备用重试不重复更新；识图四次尝试共享计时起点、结束清除；completed长连接不误重试、自然回复保留、补充原事项、失败不堵后条、单次提交、本地计划重试、停止与摘要恢复 |
| data_management/backup_service_test.dart | 时段记录与撤销快照恢复、拒绝时段携带精确时间戳或冒充发送参考时刻；schema1 / 2 / 3恢复、原回复 / 回执 / 思考保留、排除预览、恢复 / 清空删除本机预览；快照隐私与重放排除、旧文字依据恢复、整库替换 / 保留当前接口配置、可用安全副本、损坏备份拒绝、写入失败回滚、CSV、真实加解密 / 错密 / 篡改、取消选择、清除不删外部导出 |
| core/database_test.dart | 旧schema1 / 2原地升级至3，保留聊天原文、增加可空思考字段；schema1同时补自然回复和回执字段 |
| core/image_service_test.dart | 摘要落地保留预览、删聊天才清理且不删相册来源、保留草稿图片、清理孤儿、丢图保留文字、删聊天后的清理依据、路径穿越拒绝 |
| settings/model_picker_dialog_test.dart | 四个模型入口共用的选择弹窗；大小写搜索、无结果、取消 / 遮罩 / 返回、重开、键盘切换、退出动画完成前不返回和释放控制器 |
| settings/ai_settings_page_test.dart | 只填文字主模型保存、兜底收起、独立思考强度持久化、旧配置保留、只检查已填写模型并携带对应强度；每个模型失败后重试一次，分别报告、不妨碍后续检查 |
| settings/settings_repository_test.dart | 最小模型配置、图片按需与主备依赖、强度枚举及旧四模型；Base URL 规范化、保留自定义前缀、HTTP 显式同意、拒绝内嵌凭据 / 参数 / 完整接口路径 |
| core/data_test.dart | 中文时段校验 / 不生成精确时间戳、日期与时段展示；斤 / 公斤精确整数克、非法输入、日期溢出、固定时区偏移、未知时刻、营养空值与真实 0、非执行重试 scope |
| chat/reply_decoder_test.dart | 顶层 reply、任意截断边界、转义 / Unicode 代理对、隐藏协议及嵌套字段、取消令牌 |
| chat/context_builder_test.dart | 完整 envelope、重复动作、单轮 lookup、真实 ID / 版本 / 字段限制、空餐、餐内冲突、上下文去重、原标签证据与补图摘要；名称 / 别名优先于品牌、同产品旧库标签规范为库来源、歧义 / 未知 / 错单位拒绝；先前图片标签引用、0值与包装规格分离 |

模型弹窗使用真实的生产弹窗函数和主题。生命周期用例会在选择后、退出动画未结束时检查返回状态，再推进键盘变化和动画帧；不能只删掉“尚未返回”的断言来让用例通过。

本轮在原有聊天、仓库、食品拍照和备份用例中补充：未配兜底不发空模型请求（含补算）、默认省略 reasoning / 主备独立强度、所选日完整合计与空日、带日期历史、引用日期继承与新范围优先、发送标记 / 重开 / 定位，以及上下文备份恢复与非法字段拒绝。

重试用例覆盖主模型第二次成功、备用第二次成功、全部失败的四次上限、无备用的两次上限，以及食品识图相同顺序和重试状态。有效非食品结果与主动停止不继续尝试；原有 completed 长连接和只提交一份的断言保留。

本轮补充动作缺 action_key / type / state 的具体报错，以及“同餐两种食物改份量、首次缺 state、原模型收到校验反馈后修正”的确定性用例，检查输入不变、原餐和原食物只更新一次。界面用例补充空白处关闭大图 / 点图片不关闭、追问卡片间隔、标题和图标底栏。上述自动化用例尚未执行；MuMu 上的一条真实模型重试结果单独记录于 docs/10，不代替这些固定输入回归。

0.1.14 补充固定输入回归：资料库别名进入上下文，模型误写标签来源时仍用库原值折算250毫升，只更新原食物一次；先前识图摘要可在后续保存资料的建议中引用，真实0和330毫升规格保留，建议待确认而非自动入库，失败回执不重复自然回复。think 覆盖 HTTP / SSE 增量先于正文、done 去重、公开摘要优先、不显示 encrypted_content、按需请求摘要、独立保存、停止保留，以及历史 / 引用不再发送思考。备份覆盖 schema1 / 2 / 3 和思考恢复；搜索定位旧消息更新后刷新原气泡且不插入最新窗口。仅完成静态分析，尚未执行这些用例。

协议单元用例中的替身仓库和配置若被访问会直接抛错。其他用例只读写各自创建的系统临时目录与测试 SQLite 库；测试结束关闭库并清理自己的目录，不接触应用真实数据库、相册或导出文件。安全存储与文件选择器使用测试替身，HTTP 仅绑定 127.0.0.1 的随机端口，所有请求使用虚构凭据，不访问外部 AI 服务。

食品拍照用例替换相机平台通道与压缩器，使用临时小图和本机 HTTP 服务，保留生产表单、解析、图片生命周期与 SQLite 保存路径。系统相机和实际标签识别质量由设备验收确认。

0.1.15 补充：三张同一食品照片只发一次识图，第四张拒绝，备注映射与手动保存后清理照片；识别模态框不能被返回或遮罩关闭，完成后仍在表单并提示人工保存；相机进程恢复照片和表单、不混入聊天。折叠区统一为48dp标题热区，think正文可点击收起，既有卡片状态保留用例同步；图片本体和空白处均可点击返回。最终协议失败保留已流出的回复并标记未保存，旧回执重复正文只显示一次。上述自动化用例未运行。

优先处理失败的阻断类用例，不删除断言、跳过用例或放宽已保存数据的约束来消除失败。加密用例使用生产的 600,000 轮派生参数，单项允许最多两分钟；不要为提速降低安全参数。手机端系统选择器、安全存储与完整界面表现仍需设备验收。

## 报告需要什么

请提供 Flutter / Dart 版本、执行命令、失败测试名称，以及**第一条异常和完整堆栈**。若仅手机上复现，再补充 Android 版本、点击步骤、键盘是否打开、具体是在进入详情、展开依据、编辑保存，还是打开弹窗 / 选择模型后出错；无需提供 Key 或私人请求内容。
