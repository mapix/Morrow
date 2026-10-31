# Morrow

原生 AI 邮件伙伴，使用 SwiftUI 构建 macOS 与 iPhone 客户端。

自动索引来信，按联系人组织往来，集中管理附件。通过多会话 Chat 委托工作，准备回复与报告，管理长期记忆和限定范围的自动响应器。支持文件、图片、语音输入，以及语言、主题和布局密度切换。

[主页](https://morrow.novarock.io) · [下载](https://github.com/mapix/Morrow/releases)

macOS 需要 Apple Silicon 和 macOS 26，iPhone 需要 iOS 26。向量推理使用固定版本的 EmbeddingGemma 2，在本机生成 768 维向量。模型权重独立下载，不存入 Git。

密码和登录 token 位于 Keychain。远程模型会收到你选择交给它的内容；iCloud 默认关闭，邮箱正文由各设备连接邮件服务获取。邮件外部图片默认加载，可在设置或单封邮件中关闭；脚本保持禁用。

构建与本地 OAuth 配置见仓库首页。项目使用 Apache 2.0 开源许可。
