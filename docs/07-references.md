# 07 参考资料与实现边界

资料核对日期：**2026-10-19**。外部契约、参考设计、本项目选择和真实设备结果分开管理。

## 1. 需求和视觉来源

[用户提供的分享对话](https://chatgpt.com/share/6ad62c74-a444-83ea-9f21-6a84cade9c97) 是产品和界面参考。完整文字、整体概念图和相关组件代码已读取；采用用户逐项选定设计，明确否定内容不恢复。用户本轮说明末尾精简是因为反复提问，不作为删除已选功能的依据。

来源组件和代码节选见08；D01–D03 的已确认选择见09。分享页可见代码是DIL / GenUI而非Flutter，原讨论按钮不属于APP接口，整体概念图用于视觉参考。

## 2. OpenAI 官方接口

| 原始资料 | 采用事实 |
| --- | --- |
| [Responses文本](https://developers.openai.com/api/docs/guides/text) | input / instructions、output中最终助手文字，不能假设固定output[0] |
| [Responses资源与状态](https://developers.openai.com/api/reference/go/resources/responses) | 模型completed与本地提交状态分开 |
| [Streaming Responses](https://developers.openai.com/api/docs/guides/streaming-responses) | stream=true，文本delta和completed / error事件；用于04流式边界 |
| [图片输入](https://developers.openai.com/api/docs/guides/images-vision) | input_image、data URL和图片detail |
| [模型列表](https://developers.openai.com/api/reference/resources/models/methods/list) | data中的模型ID；列表不代表能力已验证 |
| [会话状态](https://developers.openai.com/api/docs/guides/conversation-state) | 客户端可提供历史，本项目不依赖远程会话 |
| [数据处理](https://developers.openai.com/api/docs/guides/your-data) | store=false不等同第三方零日志承诺 |

本项目只用 /responses 和 /models。饮食JSON、lookup、子操作、流式JSON中reply字段是本项目协议，不是API原生业务能力。可查到官方function calling说明不代表本项目强制使用tools；不增加兼容层来掩盖实际模型不能遵循约定。

文字模型需支持SSE和业务JSON，图片模型需支持图像和摘要JSON。真实代理的路径、授权、状态、SSE事件与输出质量待用户配置实际服务后确认；当前无真实Key调用证据。

## 3. Flutter、SQLite和设备依赖

| 资料 | 用途 |
| --- | --- |
| [Flutter SQLite](https://docs.flutter.dev/cookbook/persistence/sqlite) | 本地关系数据和参数绑定 |
| [sqflite](https://pub.dev/packages/sqflite) | 事务、迁移、事务对象和回滚 |
| [SQLite外键](https://www.sqlite.org/foreignkeys.html) | 显式开启外键、正确关联删除方向 |
| [http](https://pub.dev/packages/http) | 请求、流和取消，不启用透明RetryClient |
| [image_picker](https://pub.dev/packages/image_picker) | 系统选择器、Android活动恢复、临时拍照结果 |
| [flutter_image_compress](https://github.com/fluttercandies/flutter_image_compress) | 压缩、朝向、EXIF与实际尺寸参数 |
| [path_provider](https://pub.dev/packages/path_provider) | 私有目录，不硬编码Android路径 |
| [flutter_file_dialog](https://pub.dev/documentation/flutter_file_dialog/latest/index.html) | Android系统文件导入导出 |
| [uuid](https://pub.dev/packages/uuid) | 客户端稳定实体标识 |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) | 安全保存Key与备份相关限制 |
| [cryptography](https://pub.dev/packages/cryptography) | 成熟AES-GCM、PBKDF2和安全随机数能力；不自写算法 |
| [Android自动备份](https://developer.android.com/identity/data/autobackup) | 云备份与设备迁移有独立规则，不能只靠allowBackup |
| [AGP 8.2](https://developer.android.com/build/releases/agp-8-2-0-release-notes) | 与 Gradle 8.2、JDK 17、API 34 配套 |

Android是唯一运行目标，Windows是开发宿主。不因文档存Windows就增加桌面SQLite或跨平台应用适配。

## 4. 本项目初始约定

| 项目 | 约定 |
| --- | --- |
| Android | 最低API24，compile / target 34；实际工具链见10 |
| 状态 / 路由 | ChangeNotifier / Navigator，三页保留状态 |
| 桌面快捷方式 | [Android 静态快捷方式](https://developer.android.com/develop/ui/compose/system/shortcuts/creating-shortcuts)和[任务转发规则](https://developer.android.com/develop/ui/compose/system/shortcuts/managing-shortcuts)，通过原生 Activity / Flutter MethodChannel 接入，不新增插件 |
| 网络 | Responses-only、store=false；text流式、vision摘要可非流式 |
| 主备 | D10：主模型最多两次，仍失败才切已配备用，备用最多两次；全部模型调用入口覆盖，有界一次lookup往返 |
| 图文路径 | D03已确认A，两阶段，见09 |
| 直接编辑 / 引用 | D01、D02已确认A，直接编辑和长按引用，见09 |
| 单次截止 | text90秒、vision120秒，取消与代次保护 |
| 上下文 | 近期12条消息、20食物、10体重、明确日期每日50项；食品精简目录及选取的完整条目，业务历史不整库发送，现行规则见04 |
| 图片 | 3张、JPEG、长边约1600 / 质量85起、压缩后5MiB/张；私有预览随聊天保留和删除，不进备份 |
| 本地动作 | 每独立事项事务，软删除、版本保护、前后快照和逐项撤销 |
| 补算 | 所有日期缺失字段，每批10项，前台正常成功后且用户队列空闲 |
| 备份 | format1 / schema2快照，接受schema1恢复；CSV另用；可选密码信封，不含Key / AI配置 / 图片 |
| 加密参数 | 05中的固定格式1、PBKDF2和AES-GCM参数；不是性能承诺 |
| 导入 | 原文件与解密内容各100MiB上限，整库替换，先安全副本 |
| 外观 | 参考蜜桃 / 奶油白体系，深色 / 跟随系统，可读字号与48dp点击区 |

这些是设计选择，不是服务商或设备保证。修改常量须说明实际原因并同步受影响文档，不静默扩大功能。

## 5. 实施记录与待用户验收的信息

- 工具链、applicationId、版本和构建证据已记入10，插件以 pubspec.lock 为准。
- D01–D03 均确认 A，已记入09并实现。
- 用户验收需确认目标设备 Android 版本，以及实际服务模型列表、四角色能力和输出质量；只记录脱敏错误，不记录 Key。

## 6. 文档维护

需求01、交互02、数据03、AI04、状态和安全05、计划06、外部依据07、设计来源08、决策09、实现证据10。一个字段只在03定义，一种网络协议只在04定义；其他文件引用，不另造矛盾契约。

临时进度和待确认事项不写AGENTS。默认不新增或执行测试，不把文档阅读、JSON示例或源代码参考说成实际产品已验收。
