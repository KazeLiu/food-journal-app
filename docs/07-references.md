# 07 参考资料与实现边界

资料核对日期：**2026-10-19**。本文件区分外部接口事实与本项目选择，便于实现时回到原始契约确认。

## 1. Responses API 是唯一生成接口

| 原始资料 | 本项目采用的事实与位置 |
| --- | --- |
| [OpenAI 官方文本生成](https://developers.openai.com/api/docs/guides/text) | Responses 使用 input / instructions；最终文字在 output 消息内容中；SDK聚合属性不能等同原始HTTP结构。用于04请求与解析 |
| [Responses 资源与状态](https://developers.openai.com/api/reference/go/resources/responses) | 区分completed、failed、incomplete等响应状态；模型完成与本地提交分别处理 |
| [OpenAI 官方图片输入](https://developers.openai.com/api/docs/guides/images-vision) | input_image、data URL与图片细节参数。用于一次最多3图的同轮请求 |
| [OpenAI 官方模型列表](https://developers.openai.com/api/reference/resources/models/methods/list) | GET /models返回基本模型信息；客户端从ID选择，不把列表当图片能力检查 |
| [OpenAI 官方会话状态](https://developers.openai.com/api/docs/guides/conversation-state) | 可由客户端提供历史；本项目选择每轮自带必要本地上下文，不依赖远程会话 |
| [OpenAI 官方数据处理说明](https://developers.openai.com/api/docs/guides/your-data) | 请求存储与服务日志 / 数据处理并非同一概念；store=false不被描述为服务商零保留承诺 |

服务要求：能按约定处理 Responses 的同步文字 / 图片输入、返回可解析的最终文本。生成、模型检查和补算只有 `POST {base_url}/responses` 这一条路径，模型列表另用 `GET {base_url}/models`。

官方资料用于确定客户端契约；第三方服务的鉴权、模型权限、状态字段和图片处理在M2、M3使用实际配置确认。

## 2. Flutter、SQLite 与设备能力

| 原始资料 | 采用内容 |
| --- | --- |
| [Flutter SQLite使用](https://docs.flutter.dev/cookbook/persistence/sqlite) | 使用sqflite保存本地结构数据，参数化查询 |
| [sqflite维护者文档](https://pub.dev/packages/sqflite) | 数据库事务、迁移、事务对象使用和异常回滚；用于操作与回执原子提交 |
| [SQLite外键](https://www.sqlite.org/foreignkeys.html) | 连接需显式启用外键，删除方向决定关联数据是否保留 |
| [http维护者文档](https://pub.dev/packages/http) | 普通HTTP客户端与AbortableRequest取消；本项目不用透明RetryClient |
| [image_picker维护者文档](https://pub.dev/packages/image_picker) | Android系统选择器、API24起、活动重建丢失结果恢复、拍照缓存的临时性 |
| [flutter_image_compress维护者仓库](https://github.com/fluttercandies/flutter_image_compress) | 原生压缩、方向和EXIF选项；尺寸参数不能仅凭名字当作硬性最长边 |
| [path_provider维护者文档](https://pub.dev/packages/path_provider) | 获取APP适用私有目录，不硬编码Android绝对路径 |
| [flutter_file_dialog维护者文档](https://pub.dev/documentation/flutter_file_dialog/latest/index.html) | Android API24起的文件选择与保存，供备份导入导出 |
| [uuid维护者文档](https://pub.dev/packages/uuid) | 客户端生成稳定实体与操作标识，不手写随机ID算法 |

本项目只交付 Android。Windows 是开发宿主，不因文档放在Windows上就增加桌面运行、桌面SQLite适配或跨平台文件选择工作。

## 3. 凭据与平台备份

- [flutter_secure_storage维护者文档](https://pub.dev/packages/flutter_secure_storage)：安全保存敏感字符串，Android备份处理需要显式配置。选择默认安全存储，不引入生物识别、额外口令或自建加密算法。
- [Android官方自动备份](https://developer.android.com/identity/data/autobackup)：系统默认备份和设备迁移有独立规则，Android版本会影响配置方式。手动导出功能不能代替系统备份排除配置。

实现时按实际锁定插件版本确认生成的Android存储位置与备份排除项；不凭包名猜测所有设备上的文件名。

## 4. 项目选择，不是外部协议保证

下列默认值为V1的具体实现约定：

| 项目 | 约定 |
| --- | --- |
| Android最低版本 | API24 |
| 前台聊天 | 可连续入队、单任务串行，失败 / 澄清暂停 |
| 网络生成 | Responses非流式、store=false、不建立远程会话 |
| 业务结构 | 提示词JSON + 本地协议校验，不强制工具调用或原生JSON Schema |
| 主备 | 每轮同类型主一次、兜底一次；失败不自动切换其他接口 |
| 单模型截止时间 | 文字90秒、图片120秒 |
| 上下文 | 近期12条已处理消息、近期20项食物、10次体重、明确日期候选每日期最多50项，按ID去重 |
| 图片 | 最多3张；JPEG、长边约1600、质量85起点；压缩后每张最多5MiB |
| 补算 | 前台正常AI成功且队列清空后触发，单批最多10项，覆盖各历史日期空值 |
| 备份 | format1 / schema1的UTF-8 JSON；不含Key、AI配置、图片、草稿和可重放状态 |
| 恢复 | 整库业务替换，先保留最近一份安全副本；初始导入上限100MiB |
| 外观 | 浅色温柔配色、系统字体、原生组件，三页导航 |

图片识别表现、接口可接受大小与实际耗时在M2、M3确认。真实输入改变了条件时，在受影响模块调整常量与文档，保持单一接口和最小实现。

## 5. 开始编码时记录的环境

在实现记录中填写实际值，不在设计阶段捏造：

- Flutter / Dart、JDK、Android SDK、Gradle与插件锁定版本。
- applicationId、显示名、最低SDK、版本号和签名保存位置；不记录签名密码或私钥内容。
- 目标设备Android版本、是否真实设备、允许执行的运行 / 构建 / 验收范围。
- 用户在APP中配置的服务是否提供模型列表、四个模型角色的实际调用结果；记录模型ID与脱敏错误，不记录Key。

## 6. 文档维护方式

需求规则先更新01；交互更新02；字段、状态、删除关系更新03；Responses和业务操作格式更新04；补算、队列、图片和恢复行为更新05；任务与验收同步06。README只保留入口和核心决定。

不把临时进度、推测或待验证结论写成AGENTS.md的长期规则。实现发现真实约束后，只维护相关文档和必要的项目规则，不复制出第二套相互冲突的接口约定。
