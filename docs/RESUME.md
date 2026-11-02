# 持续目标与恢复入口

用户目标：Swift原生邮件伙伴，EmbeddingGemma 2索引、常用网易邮箱客户端能力及主动代理。主要UI与demo迭代已验收；用户最新明确要求为your-account@example.com申请Smail OAuth客户端并连接Gmail。该授权取代此前仅demo的限制；不索取密码/验证码/授权码到Chat，不发送真实邮件。

## 当前产品

- macOS26 / Apple Silicon，已安装0.8.4/build24、签名通过。包含EmbeddingGemma2权重/Metal，约1.7GB。
- 安装位置`/Applications/Smail.app`。当前演示目录`evidence/private/sessions-memory-080`；旧`iteration-070-final` / `agentic-native-v3-final`保留；普通工作区`~/Library/Application Support/Smail`。
- 当前Mac已可操作，CUA偶有ScreenCaptureKit失败；必要时重新getApp或Raise后读取，不把工具错误当App挂死。最新恢复入口`docs/agentic/GMAIL-084-REGISTRATION.md`。Gmail客户端/secret已配置；当前无真实Gmail账户保存，等待用户确认当前浏览器授权页后发起新一轮（先前等待已超时）。
- `WorkHandoffSurface.swift`直接进入可操作工作稿；`WorkDocumentView.swift`内联编辑回复、约定和决定。资料/历史索引在`AgentLibraryView.swift`。
- `WorkScope.swift`绑定真实ID与后续筛选；`AgentWorkspaceModel.swift`管理报告版本/决定；`AgentDemoScenarios.swift`支持四种后续邮件。
- 研究报告在`docs/agentic/PRODUCT-HUNT-RESEARCH.md`、`GITHUB-PRODUCT-RESEARCH.md`，采用关系在`RESEARCH-ADOPTION.md`。Hallmark主题Coral，用户明确替换了Atelier；顶部应用导航条已删除，原生标题栏隐藏。

## 验收与修复

本轮0.8.4已通过主要原生验收，证据在GMAIL-084-REGISTRATION.md和native-084-proof.json；旧记录对应各自版本。真实Gmail最终认证/同步仍未验证，实际scope待获得新回调后检查。

修复：逗号列表匹配词不再作为整个字符串；编辑范围解析为实际筛选；零邮件不生成成功报告；一轮产出后保持持续关注；报告更新原文档并保留版本；旧回复保留、过时决定标明已有新版本；当前工作后续查询限制在确认范围内。

`evidence/tests-coral-delivery-062.log`：52项测试，46项通过，6个模型gate跳过，零失败。其他模型/协议证据列于`docs/DELIVERY.md`；fixture与示例投递不代表真实服务商验收。

## OpenUI / 响应器

真实模型产出的OpenUI Lang原生表单已完成编辑、保存启用和新来信自动模拟回复。完成后的设置以清晰只读记录显示，首次保存回执带时间，不再保留可重复执行的保存按钮。固定正文的用户修改保存在交互state、规则、草稿和Sent副本中。新建规则跳过历史邮件，canonical回执防重复，自动通知/回复循环抑制，暂停取消队列；响应器设置与工作状态已同步。

文件：`OpenUILang.swift`、`OpenUILibrarySpec.swift`、`NativeOpenUIView.swift`、`OpenUIModel.swift`、`MailResponder.swift`、`ResponderModel.swift`、`RespondersView.swift`。官方fixture59个，固定上游commit；不是完整官方conformance suite。Query/Mutation/远端执行不支持。

## 继续推进

1. 补可纠正、带来源和适用范围的长期上下文；把满意的一次执行转为持续责任。
2. 验证复杂后续邮件、用户修改稿保留、并发触发与提交恢复。当前成果写入仍分步进行，不是整件工作的单一事务。
3. 补完成条件自动判定和完整执行权限模型。当前结束委托由用户确认。
4. 用户将来要求真实账户时再验收服务商；Exchange、服务端规则、超大附件和容量仍未完成。
5. 完整目标保持active；demo改造不等于网易客户端全功能对等。

## 构建与启动

```sh
zsh scripts/package-app.sh
zsh scripts/test.sh
SMAIL_LIVE_WORK=1 swift test --filter WorkScopeTests/testLiveEditedScopeResolvesOnlySpecifiedContracts
open /Applications/Smail.app --args --demo --agent-demo --data-dir "$PWD/evidence/private/agentic-native-v3-final"
```

空工作区可点击“打开演示场景”。更新安装前通过CUA正常退出，保存旧应用后用ditto复制，验证codesign，再启动。真实窗口操作只用CUA；超时可能发生在动作生效后，先重新观察，不盲目重复。


## 2026-10-31 联系人与统一Chat迭代

新增`PeopleAndMaterials.swift`、`PeopleMaterialsModel.swift`、`PeopleView.swift`、`AttachmentWorkspaceView.swift`、`SidebarChatModel.swift`、`SidebarChatView.swift`、`NativeVoiceInput.swift`。档案按全部本机历史邮件参与者建立；右侧Chat随原生视图/选择/筛选/草稿感应，可固定快照或仅分析本轮资料。写信和附件文字预览改为左侧内联，保留右侧Chat。截图、文件、音频材料不伪造为邮件。

真实语音文件转写与结构化草稿编辑已验证。通用规划器的不可核验操作拒绝，不能再默默丢弃操作却保留“已完成”表述。草稿编辑固定宿主目标、结构化生成、实际保存后回执，保留用户并发修改。

恢复入口：`docs/agentic/ITERATION-073-QA.md`。最终安装/原生草稿重捕/麦克风实际状态以该文件末尾记录为准。启动追加`--iteration-demo`可重用不重复的林舟演示历史。


最终0.7.3已安装并原生验收。63项逻辑测试（55执行通过/8gate跳过），两项额外真实模型gate通过。用户现场说“打开联系人”，真实麦克风转写进入Chat并完成页面导航。当前演示库22封邮件/11个档案，原文、修正草稿、对话材料及回执均保留；最终截图`iteration-073-final-workspace.png`。无锁屏或麦克风授权阻塞。


## 2026-10-31 Session / 记忆 / 布局 / 多邮箱

0.8.0已安装并原生验收：联系人独立补充框已删除，补充统一进入Chat记忆。左侧/右侧切换Session，消息和未发送内容分离；记忆支持语义检索、作用域、有效期、版本、停用/恢复和来源管理。已读/未读更明显，模型设置与紧凑/宽松、多邮箱入口已加入。

0.8.1候选已构建，模型配置先暂存后保存应用。当前Mac锁屏，等待用户解锁完成候选安装/重启验收。详见`docs/agentic/SESSIONS-MEMORY-081-QA.md`；不得把候选当作已安装。

## 0.8.2 多视角审查后恢复

四位subagent审查与修复已完成。`dist/Smail.app` 0.8.2/build16，签名已验证；最终102项（91通过/11环境gate跳过/零失败），额外真实本机模型和loopback兼容接口通过。当前安装0.8.0；Mac锁屏，安装与UI验收pending。详细检查清单及材料范围限制见`docs/agentic/REVIEW-082-CLOSURE.md`。

## 0.8.3 frontend-design 精简

候选已替换为0.8.3/build17，包含0.8.2修复。四个主入口、管理菜单、输入旁范围锚点、折叠来源与紧凑工作稿；去除永久索引脚栏/重复介绍/默认禁用保存与附件批量按钮。32项逻辑回归通过，签名验证通过；没有新原生截图。最后CUA仍报告锁屏，实际安装0.8.0。解锁后直接安装最新dist/Smail.app，沿用evidence/private/sessions-memory-080。方案与自查：docs/agentic/DESIGN-083-PLAN.md，证明：evidence/design-083-proof.json。

## 2026-10-31 安装验收阻挡审计

自动目标续行再次使用CUA读取Smail，工具仍明确报告Mac锁屏且自动解锁失败。当前Info.plist读取：安装版0.8.0、候选0.8.3；候选严格deep签名再次验证通过，32项回归日志保持通过。前两轮分别已落实产品/用户审查修复与frontend-design精简，剩余安装、重启与真实窗口验证没有可绕过的GUI路径。同一锁屏条件连续三轮出现，目标设为blocked，等待用户解锁后恢复。没有强制杀进程、替换运行中的应用或将离线验收冒充原生验收。

恢复后仍按DESIGN-083-PLAN.md末尾清单安装最新dist/Smail.app并验收，同一演示库evidence/private/sessions-memory-080；保留所有Session、记忆、输入、资料和候选证据。完整目标未完成。
