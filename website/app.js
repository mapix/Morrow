(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  let language = 'zh';
  const t = (zh, en) => language === 'en' ? en : zh;
  const pairs = new Map($$('[data-en]').map(node => [node, node.innerHTML]));
  const chapters = [
    ['mail', ['邮件', 'Mail'], ['把多个邮箱、邮件原文与下一步工作，放到一张原生工作台上。', 'Bring your accounts, original messages, and the next step into one native workspace.'], 'mail'],
    ['search', ['检索', 'Search'], ['从大概的意思，到准确的关键词。找到邮件，也找回它的上下文。', 'From a half-remembered idea to an exact keyword. Find the message and its context.'], 'search'],
    ['people', ['人与资料', 'People & files'], ['围绕联系人整理往来，让关键附件有一个清楚的来处。', 'Gather correspondence around people and give important files a clear source.'], 'file'],
    ['chat', ['对话', 'Chat'], ['给 Morrow 一个目的，让资料变成草稿、分析和下一步。', 'Give Morrow a goal. Turn your material into drafts, analysis, and a next step.'], 'spark'],
    ['memory', ['记忆', 'Memory'], ['有用的偏好和上下文，留给下一次工作。', 'Keep useful preferences and context ready for the next conversation.'], 'spark'],
    ['responders', ['自动响应', 'Responders'], ['明确范围、先行试跑，让重复的事情按约定推进。', 'Set the scope and test the rule. Let recurring work follow your instructions.'], 'mail'],
    ['models', ['模型选择', 'Your models'], ['本机模型、自选服务或 ChatGPT。工作方式由你选择。', 'Local models, your model service, or ChatGPT. Choose how you want to work.'], 'spark'],
    ['native', ['原生 Mac', 'Made for Mac'], ['原生窗口、键盘操作、可选同步，以及开放的源码。', 'Native windows, keyboard workflows, optional sync, and open source.'], 'grid']
  ];
  const features = {
    mail: { chapter: 0, icon: 'mail', title: ['所有邮箱，同一张工作台。', 'All your mail. One place to think.'], description: ['在 Morrow 中阅读原邮件、查看附件，并在旁边的对话里继续处理工作。邮件列表、原文与辅助对话互相连接，资料不必反复搬来搬去。', 'Read the original message, inspect its attachments, and continue the work in the conversation beside it. The message list, source, and chat stay connected.'], notes: [['多邮箱集中管理，账户和文件夹仍保持清晰。', 'Multiple mailboxes stay together, with clear accounts and folders.'], ['回复与转发支持草稿、预览和附件。', 'Replies and forwards support drafts, preview, and attachments.'], ['页面展示的是当前原生项目界面，公开下载以发布说明为准。', 'This is the current native project interface; the public download is defined by its release notes.']] },
    accounts: { chapter: 0, icon: 'mail', title: ['把邮箱连起来', 'Your accounts, together'], description: ['连接多个 IMAP/SMTP 邮箱，使用 Gmail OAuth 登录，或接收 POP3 邮件。Morrow 是你的邮件客户端，现有的邮箱地址与邮件服务仍然保留。', 'Connect multiple IMAP/SMTP mailboxes, use Gmail OAuth, or receive POP3 mail. Morrow is your mail client; your existing address and provider stay in place.'], notes: [['邮箱凭据保存在 macOS Keychain。', 'Mail credentials are stored in the macOS Keychain.'], ['各台 Mac 从邮件服务获取邮件。', 'Each Mac obtains its mail from the provider.']] },
    compose: { chapter: 0, icon: 'mail', title: ['把回复准备好', 'A thoughtful next reply'], description: ['从当前邮件开始回复或转发，查看草稿内容、补充附件，再决定什么时候发送。也可以请 Morrow 根据指定资料准备初稿。', 'Reply or forward from the current message, inspect the draft, add attachments, and choose when to send. You can also ask Morrow to prepare a draft from selected material.'], notes: [['自动响应规则的发送权限在应用内单独设置。', 'Automatic responder delivery is configured separately in the app.'], ['网页演示不会执行任何邮件操作。', 'The website examples perform no mail actions.']] },
    translation: { chapter: 0, icon: 'spark', title: ['跨过语言这一关', 'Read across languages'], description: ['使用配置的模型翻译邮件，原始邮件仍可查看。长邮件分段处理，已经完成的部分先显示；未完成的翻译会保留状态。', 'Translate a message using your configured model while keeping the original available. Long messages are handled in parts; completed sections appear first and unfinished translations stay marked.'], notes: [['翻译会把所需内容交给选定模型。', 'Translation supplies the required content to the selected model.'], ['具体效果取决于模型与上下文长度。', 'Results depend on the model and its context window.']] },
    search: { chapter: 1, icon: 'search', title: ['从意思出发，找到那封邮件。', 'Search the way you remember.'], description: ['语义检索使用本机 EmbeddingGemma 2 索引，把问题与相关邮件连接起来。知道准确线索时，可以使用关键词、联系人、账户与文件夹范围。', 'Semantic search uses a local EmbeddingGemma 2 index to connect a question with related mail. When you know the exact clue, use keywords, people, accounts, and folders.'], notes: [['向量索引在本机建立，不使用模型 API 额度。', 'The embedding index is built locally without model API usage.'], ['命中结果保留原邮件，方便核验。', 'Results retain the original message for verification.'], ['网页演示仅展示固定虚构结果。', 'The website demo displays fixed fictional results.']] },
    people: { chapter: 2, icon: 'mail', title: ['把往来连成联系人档案', 'The person behind the thread'], description: ['从邮件往来中整理联系人信息、上下文和可核验线索。把结论与原始来源放在一起，让后续沟通有据可查。', 'Organize contact information, context, and verifiable clues from correspondence. Keep conclusions beside their sources so the next conversation has a useful history.'], notes: [['联系人档案与历史往来保持关联。', 'Contact profiles stay linked to their correspondence.'], ['线索可以回到原邮件核对。', 'Clues can be checked against the original message.']] },
    attachments: { chapter: 2, icon: 'file', title: ['资料，不再散落在邮件里', 'A home for the files that matter'], description: ['在统一入口按文件类型与来源查找附件，查看原件、预览和保存。把附件交给对话时，它会成为这一件工作的资料。', 'Find attachments in one place by file type and source. Inspect, preview, and save the original. Bring a file into Chat as material for the task at hand.'], notes: [['支持图片、文档与其他附件资料管理。', 'Manage images, documents, and other attachments.'], ['原邮件来源随资料保留。', 'The originating message stays linked to the file.']] },
    chat: { chapter: 3, icon: 'spark', title: ['一个能一起做事的对话。', 'A conversation that can work with you.'], description: ['为一件工作保留独立对话、输入和上下文。给出目的并选择阅读范围，Morrow 可以检索邮件、读取资料、准备草稿和整理报告。', 'Keep a separate conversation, inputs, and context for each task. Set a goal and a reading scope; Morrow can search mail, read material, prepare drafts, and organize reports.'], notes: [['提交时捕获阅读范围，之后切换邮箱不会扩大当前请求。', 'The reading scope is captured on submission; changing mailboxes does not expand that request.'], ['普通问题不会预先读取整个收件箱正文。', 'An ordinary question does not preload every inbox message body.'], ['相关原邮件和资料可作为核验依据。', 'Related original mail and files remain available as evidence.']], doc: 'CONFIGURATION.md' },
    multimodal: { chapter: 3, icon: 'file', title: ['不只打字', 'Bring more than words'], description: ['在对话中加入文件、截图、图片或语音。资料与当前工作保持在一起，避免在不同工具之间反复解释背景。', 'Add files, screenshots, images, or voice to the conversation. Keep the material with its task so the context is easier to carry forward.'], notes: [['具体处理能力取决于所选模型与配置。', 'Processing capabilities depend on the selected model and configuration.'], ['重要输出可以保存为资料或导出。', 'Important outputs can be saved as materials or exported.']] },
    analysis: { chapter: 3, icon: 'grid', title: ['让资料变成可用结果', 'Work through the details'], description: ['Chat 可以在明确范围内使用 Python 和 SQL，读取邮件和联系人数据进行分析。把往来整理为清单、比较结果或报告，再核对原始依据。', 'Chat can use Python and SQL to analyze scoped mail and contact data. Turn correspondence into lists, comparisons, or reports and verify them against the source.'], notes: [['分析在只读沙箱中访问限定数据。', 'Analysis accesses scoped data in a read-only sandbox.'], ['示意图仅表示报告形态，没有实际业绩数字。', 'The illustration represents a report; it contains no real performance metrics.']] },
    openui: { chapter: 3, icon: 'grid', title: ['需要决定时，直接选择', 'A clearer way to decide'], description: ['对话可以使用结构化选项、表单和表格来收集要求。选择资料范围、核对计划，再继续下一步处理。', 'Chat can collect requirements through structured choices, forms, and tables. Choose the scope, review the plan, and continue the task.'], notes: [['选择与原始对话上下文保持关联。', 'Selections stay connected to the original conversation.'], ['功能表现取决于当前版本与模型输出。', 'Availability and behavior depend on the version and model output.']] },
    memory: { chapter: 4, icon: 'spark', title: ['有些事，不必每次重说。', 'Some things should not need repeating.'], description: ['把有用的偏好和上下文存为可编辑的记忆。查看来源、范围和历史版本，确认、修改、停用或忘记已有内容。', 'Save useful preferences and context as editable memory. Review sources, scope, and history, then confirm, edit, pause, or forget what is stored.'], notes: [['记忆管理有明确的编辑与停用入口。', 'Memory has explicit editing and pause controls.'], ['此页面的偏好修改只影响虚构示例，刷新后重置。', 'Preference edits here affect the fictional example only and reset on reload.']] },
    responders: { chapter: 5, icon: 'mail', title: ['说清楚条件，再交给 Morrow。', 'Set the rules. See what happens.'], description: ['创建有范围的自动响应规则，限定邮箱、文件夹、发件人和内容条件。先用试跑检查处理结果，再选择草稿或已明确授权的自动发送。', 'Create scoped automatic responders with mailbox, folder, sender, and content conditions. Test the result first, then choose drafts or explicitly authorized automatic sending.'], notes: [['启用前应查看规则范围与发送方式。', 'Review the rule scope and delivery behavior before enabling it.'], ['自动发送需要在应用内显式授权。', 'Automatic sending requires explicit authorization in the app.'], ['网页试跑不会连接邮箱或发送消息。', 'The website simulation does not connect to mailboxes or send messages.']] },
    models: { chapter: 6, icon: 'spark', title: ['你的工作台，你选择的智能。', 'Your workspace. Your choice of intelligence.'], description: ['选择本机 Ollama 或 Apple Intelligence、兼容的 HTTPS 模型服务，或原生 ChatGPT 登录。模型设置决定任务内容在哪里处理。', 'Choose local Ollama or Apple Intelligence, a compatible HTTPS model service, or native ChatGPT sign-in. Your model settings determine where task content is processed.'], notes: [['模型 API 凭据保存在 Keychain。', 'Model API credentials are stored in Keychain.'], ['使用远程模型时，任务所需内容会发送给所选服务。', 'When using a remote model, required task content is sent to that service.'], ['本机语义索引与模型服务选择相互独立。', 'The local semantic index is independent of the model service.']], doc: 'CONFIGURATION.md' },
    appearance: { chapter: 7, icon: 'grid', title: ['按你的习惯摆好', 'Make room for your way'], description: ['在原生应用中选择语言、主题和布局密度，让长时间处理邮件的工作台更适合你。', 'Choose language, theme, and layout density in the native app to suit the way you work with mail.'], notes: [['网页的三种配色用于本次产品展览。', 'The website’s three palettes belong to this product exhibition.'], ['应用内外观设置与网页选择互相独立。', 'Native app appearance settings are separate from this website.']] },
    icloud: { chapter: 7, icon: 'file', title: ['在另一台 Mac 接着做', 'Continue on another Mac'], description: ['可选的 iCloud 工作空间同步覆盖对话、记忆、联系人和资料。默认关闭；每台 Mac 仍从邮件服务获取邮件。', 'Optional iCloud workspace sync covers chat, memory, contacts, and artifacts. It starts off; each Mac still obtains mail from the provider.'], notes: [['同步需要具有授权容器的正确签名构建。', 'Sync requires a properly signed build with an authorized container.'], ['由你选择是否启用。', 'You choose whether to enable it.']], doc: 'DATA.md' },
    opensource: { chapter: 7, icon: 'grid', title: ['源码，向你开放', 'Open to look inside'], description: ['Morrow 采用 Apache 2.0 协议开源。阅读原生应用与运行时源码，使用自己的配置构建，或通过 GitHub 问题与贡献参与项目。', 'Morrow is open source under Apache 2.0. Read the native app and runtime source, build with your own configuration, or contribute through GitHub issues and pull requests.'], notes: [['依赖与模型遵循各自的许可证。', 'Dependencies and models retain their own licenses.'], ['公开版本说明记录已验证行为与限制。', 'Public release notes describe tested behavior and limitations.']] }
  };
  let selectedQuery = 'delivery', selectedSession = 'delivery', selectedContact = 'lin', selectedModel = 'local', responseMode = 'draft', expoIndex = 0;
  let memoryPaused = false, customMemory = '', currentFeature = null, downloadManifest = null, downloadState = 'pending';
  const queryData = {
    delivery: { query: ['上次聊到交付时间的邮件', 'The messages about our delivery date'], rows: [['JL', ['林佳', 'Jia Lin'], ['交付时间与材料清单', 'Delivery date and material checklist'], ['清单已经更新，我们按周五的时间安排继续。', 'The checklist is updated. We can continue with the Friday schedule.'], '10:24'], ['AC', ['Alex Chen', 'Alex Chen'], ['Re: 项目进度', 'Re: Project timeline'], ['附件里是新版计划，交付日期已标在第二页。', 'The updated plan is attached, with the delivery date on page two.'], ['昨天', 'Yesterday']]] },
    file: { query: ['带有项目清单 PDF 的邮件', 'Mail with the project brief PDF'], rows: [['JL', ['林佳', 'Jia Lin'], ['附件：项目清单', 'Attachment: project brief'], ['project-brief.pdf — 本次交付的材料与检查项。', 'project-brief.pdf — Materials and review items for this delivery.'], '09:18'], ['AC', ['Alex Chen', 'Alex Chen'], ['更新后的项目清单', 'Updated project brief'], ['project-brief-v2.pdf — 已补充设计参考。', 'project-brief-v2.pdf — Now includes the design reference.'], ['周一', 'Monday']]] },
    person: { query: ['来自林佳的项目往来', 'Project correspondence from Jia Lin'], rows: [['JL', ['林佳', 'Jia Lin'], ['这周的项目进度', 'This week’s project progress'], ['我会先整理已收到的资料，缺项周五前确认。', 'I will organize the material received and confirm missing items by Friday.'], '10:24'], ['JL', ['林佳', 'Jia Lin'], ['补充：设计参考', 'Follow-up: design reference'], ['补上上次提到的参考图，请查收。', 'Here is the reference image mentioned in our last conversation.'], ['昨天', 'Yesterday']]] }
  };
  const sessionData = {
    delivery: { question: ['帮我核对这次交付还缺哪些材料。', 'Help me check which materials are missing for this delivery.'], heading: ['先把事情理清楚。', 'Let’s make the next step clear.'], answer: ['已收到项目清单与设计参考。费用明细还需要确认，我会把未确认的内容单独列出。', 'The project brief and design reference are here. The budget breakdown still needs confirmation, so I’ll list it separately.'], action: ['准备回复草稿', 'Prepare a reply'], result: ['草稿已准备：项目清单与设计参考已收到。请补充费用明细，未确认项已单独列出。此示例没有发送邮件。', 'Draft prepared: The project brief and design reference are received. Please add the budget breakdown. Unconfirmed items are listed separately. Nothing was sent.'] },
    billing: { question: ['把这些账单按项目整理一下。', 'Organize these invoices by project.'], heading: ['先核对，再汇总。', 'Check the source, then summarize.'], answer: ['先按项目归类，再检查日期与币种。缺少项目名称的账单放进待确认清单，避免混入汇总。', 'Group the invoices by project, then check dates and currencies. Put invoices without a project name into a review list.'], action: ['生成整理清单', 'Prepare the checklist'], result: ['清单已准备：项目、账单日期、币种、原邮件来源。缺少项目名称的条目列为待确认。', 'Checklist prepared: project, invoice date, currency, and source message. Items without a project name are marked for review.'] },
    planning: { question: ['根据这些往来，帮我整理本周要跟进的事。', 'Use this correspondence to prepare my follow-ups for the week.'], heading: ['让下一步具体一点。', 'Make the next step concrete.'], answer: ['本周需要确认交付清单、核对费用明细，并回复设计参考。未明确的时间不会被当作已确认的截止日期。', 'Confirm the delivery checklist, review the budget breakdown, and respond to the design reference. Unclear dates are not treated as confirmed deadlines.'], action: ['整理跟进计划', 'Prepare the follow-up plan'], result: ['计划已准备：确认清单 → 核对明细 → 回复参考。每项保留来源，待确认日期单独标出。', 'Plan prepared: confirm the checklist, review the breakdown, reply about the reference. Each item keeps its source; unconfirmed dates are separate.'] }
  };
  const contactData = {
    lin: [['林佳', 'Jia Lin'], ['项目交付', 'Project delivery'], ['往来邮件、相关资料与可核验的线索，放在一起。', 'Correspondence, related files, and verifiable context, brought together.']],
    alex: [['Alex Chen', 'Alex Chen'], ['设计协作', 'Design collaboration'], ['从参考图到新版计划，找到这段协作的原始依据。', 'From reference images to the revised plan, find the sources behind the collaboration.']]
  };
  const modelData = {
    local: [['让本机模型参与工作。', 'Bring a local model into the work.'], ['选择本机模型时，模型处理可在 Mac 上进行。邮箱仍通过你的邮件服务同步，本机语义索引独立运行。', 'When you select a local model, model processing can happen on your Mac. Mail still syncs through your provider, and the local semantic index runs independently.'], '⌘'],
    api: [['使用你信任的模型服务。', 'Use a model service you trust.'], ['配置兼容的 HTTPS 服务与模型。任务所需邮件和资料会发送到所选服务，API 凭据保存在 Keychain。', 'Configure a compatible HTTPS endpoint and model. Required mail and material are sent to that service, while API credentials stay in Keychain.'], 'API'],
    chatgpt: [['在原生应用中登录 ChatGPT。', 'Sign in to ChatGPT in the native app.'], ['使用原生 ChatGPT 登录参与对话工作。处理内容会交给相应服务，具体可用能力取决于登录与配置。', 'Use native ChatGPT sign-in for conversation tasks. Content is processed by that service; available capabilities depend on sign-in and configuration.'], '✳']
  };
  function pair(value) { return Array.isArray(value) ? value[language === 'en' ? 1 : 0] : value; }
  function element(tag, text, className) { const node = document.createElement(tag); if (text !== undefined) node.textContent = text; if (className) node.className = className; return node; }
  function renderQuery() {
    const data = queryData[selectedQuery]; $('#search-query').textContent = pair(data.query);
    $('#search-results').replaceChildren(...data.rows.map((row, index) => {
      const result = element('div', undefined, 'mail-result');
      const copy = element('div'); copy.append(element('strong', pair(row[1])), element('span', pair(row[2])), element('p', pair(row[3])));
      result.append(element('span', row[0], 'avatar' + (index ? ' pale' : '')), copy, element('time', pair(row[4]))); return result;
    }));
  }
  function renderSession() {
    const data = sessionData[selectedSession]; $('#chat-question').textContent = pair(data.question);
    const source = element('button', t('查看 2 封来源邮件', 'View 2 source messages'), 'source-reference'); source.id = 'source-reference'; source.addEventListener('click', showSource);
    $('#chat-answer').replaceChildren(element('strong', pair(data.heading)), element('p', pair(data.answer)), source);
    $('#chat-run span').textContent = pair(data.action); $('#chat-result').hidden = true; $('#chat-run').disabled = false;
  }
  function renderContact() {
    const data = contactData[selectedContact]; $('#contact-excerpt').replaceChildren(element('strong', pair(data[0])), element('span', pair(data[1])), element('p', pair(data[2])));
    $$('[data-contact]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.contact === selectedContact)));
  }
  function renderModel() { const data = modelData[selectedModel]; $('#model-heading').textContent = pair(data[0]); $('#model-description').textContent = pair(data[1]); $('.model-path-target').textContent = data[2]; }
  function renderMemory() {
    $('#memory-example').textContent = customMemory || t('回复保持简短中文。', 'Keep replies brief and in English.');
    $('#memory-pause').textContent = memoryPaused ? t('恢复', 'Resume') : t('停用', 'Pause');
    $('#memory-pause').setAttribute('aria-pressed', String(memoryPaused)); $('.memory-sheet').classList.toggle('paused', memoryPaused);
  }
  function renderResponse() { $('#rule-result').classList.remove('tested'); $('#rule-result').textContent = responseMode === 'draft' ? t('匹配后准备草稿，由你审阅。点击试跑查看示例。', 'Prepare a draft for your review. Test the rule to see the example.') : t('应用内自动发送需要明确授权。点击试跑查看示例。', 'Automatic sending requires explicit authorization in the app. Test the example.'); }
  function applyLanguage(next) {
    language = next === 'en' ? 'en' : 'zh'; document.documentElement.lang = language === 'en' ? 'en' : 'zh-Hans';
    pairs.forEach((zh, node) => { node.innerHTML = language === 'en' ? node.dataset.en : zh; });
    $('#language-toggle').textContent = language === 'en' ? '中文' : 'EN'; $('#language-toggle').setAttribute('aria-label', language === 'en' ? '切换到中文' : 'Switch to English');
    $('#feature-search').placeholder = t('搜索功能、工作方式…', 'Search features, workflows…');
    document.title = t('Morrow — 邮件之外，工作继续。', 'Morrow — Your mail. In motion.');
    const description = t('Morrow，为 Mac 打造的 AI 邮件伙伴。把邮件、联系人、附件与下一步工作连接起来。', 'Morrow, an AI mail partner native to your Mac. Connect your mail, people, files, and what comes next.');
    $('meta[name="description"]').content = description; $('meta[property="og:description"]').content = description; $('meta[property="og:title"]').content = document.title;
    $$('.native-media img,.universe-preview img,.preview-dialog>img').forEach(img => { img.alt = t('Morrow 原生邮件工作台，全部内容均为虚构示例', 'The native Morrow mail workspace, using only fictional example content'); });
    $('#preview-open').setAttribute('aria-label', t('查看 Morrow 原生界面', 'View the native Morrow interface'));
    renderQuery(); renderSession(); renderContact(); renderModel(); renderMemory(); renderResponse(); renderSearch(); renderExpo(); updateDownload();
    if (currentFeature && $('#feature-dialog').open) populateFeature(features[currentFeature]);
    try { localStorage.setItem('morrow-language', language); } catch (_) { /* Storage is optional. */ }
  }
  let previousFocus = null;
  function openDialog(id) {
    if (!document.querySelector('dialog[open]')) previousFocus = document.activeElement;
    $$('dialog[open]').forEach(dialog => dialog.close());
    const dialog = document.getElementById(id); dialog.showModal(); document.body.classList.add('modal-open');
    if (id === 'search-dialog') $('#feature-search').focus();
  }
  $$('dialog').forEach(dialog => {
    dialog.addEventListener('close', () => { if (!document.querySelector('dialog[open]')) document.body.classList.remove('modal-open'); });
    dialog.addEventListener('click', event => { const rect = dialog.getBoundingClientRect(); if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dialog.close(); });
  });
  $$('[data-close]').forEach(button => button.addEventListener('click', () => { document.getElementById(button.dataset.close).close(); if (previousFocus?.isConnected) previousFocus.focus({preventScroll:true}); }));
  function populateDetail(category, title, description, notes, icon, doc) {
    $('#detail-category').textContent = category; $('#detail-title').textContent = title; $('#detail-description').textContent = description;
    $('#detail-notes').replaceChildren(...notes.map(note => element('p', note)));
    $('#detail-art use').setAttribute('href', '#i-' + icon); $('#detail-doc').href = doc;
  }
  function populateFeature(data) { populateDetail(pair(chapters[data.chapter][1]), pair(data.title), pair(data.description), data.notes.map(pair), data.icon, data.doc ? 'https://github.com/mapix/Morrow/blob/main/docs/public/' + data.doc : 'https://github.com/mapix/Morrow'); }
  function showFeature(key) { if (!features[key]) return; currentFeature = key; populateFeature(features[key]); openDialog('feature-dialog'); }
  $$('[data-feature]').forEach(button => button.addEventListener('click', () => showFeature(button.dataset.feature)));
  function showSource() {
    currentFeature = null;
    populateDetail(t('虚构示例来源', 'Fictional example sources'), t('结论旁边，保留原邮件。', 'Keep the source beside the conclusion.'), t('这里展示的是固定虚构来源，用来说明 Morrow 如何把工作结果与原始邮件连接起来。', 'These fixed fictional sources illustrate how Morrow connects a result with original messages.'), [t('林佳：清单已经更新，我们按周五的时间安排继续。', 'Jia Lin: The checklist is updated. We can continue with the Friday schedule.'), t('Alex Chen：附件里是新版计划，交付日期已标在第二页。', 'Alex Chen: The updated plan is attached, with the delivery date on page two.')], 'mail', 'https://github.com/mapix/Morrow'); openDialog('feature-dialog');
  }
  function renderSearch() {
    const query = $('#feature-search').value.trim().toLowerCase(); const matches = Object.entries(features).filter(([,data]) => [...data.title,...data.description,...chapters[data.chapter][1]].join(' ').toLowerCase().includes(query));
    $('#search-empty').hidden = !!matches.length;
    $('#feature-search-results').replaceChildren(...matches.map(([key,data]) => {
      const button = element('button', undefined, 'search-result'); const copy = element('span'); copy.append(element('strong', pair(data.title)),element('small', pair(chapters[data.chapter][1]))); const icon = element('span','+'); button.append(copy,icon); button.addEventListener('click', () => showFeature(key)); return button;
    }));
  }
  $('#feature-search').addEventListener('input', renderSearch); $('#search-open').addEventListener('click', () => { renderSearch(); openDialog('search-dialog'); });
  $('#menu-toggle').addEventListener('click', () => { const open = $('#chapter-menu').hidden; $('#chapter-menu').hidden = !open; $('#menu-toggle').setAttribute('aria-expanded', String(open)); });
  $('#chapter-menu').addEventListener('click', event => { if (event.target.closest('a')) { $('#chapter-menu').hidden = true; $('#menu-toggle').setAttribute('aria-expanded','false'); } });
  document.addEventListener('click', event => { if (!event.target.closest('#chapter-menu,#menu-toggle')) { $('#chapter-menu').hidden = true; $('#menu-toggle').setAttribute('aria-expanded','false'); } });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') { $('#chapter-menu').hidden = true; $('#menu-toggle').setAttribute('aria-expanded','false'); }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); openDialog('search-dialog'); }
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.target.closest('input,textarea,dialog')) { event.preventDefault(); openDialog('search-dialog'); }
  });
  function bindTabs(attribute, callback, panelId) {
    const buttons = $$('[' + attribute + ']');
    function select(button, focus = false) { buttons.forEach(item => { const active = item === button; item.setAttribute('aria-selected', String(active)); item.tabIndex = active ? 0 : -1; }); document.getElementById(panelId).setAttribute('aria-labelledby',button.id); callback(button); if (focus) button.focus({preventScroll:true}); }
    buttons.forEach((button,index) => { button.tabIndex = index ? -1 : 0; button.addEventListener('click', () => select(button)); button.addEventListener('keydown', event => { let next; if (['ArrowRight','ArrowDown'].includes(event.key)) next = (index+1)%buttons.length; if (['ArrowLeft','ArrowUp'].includes(event.key)) next = (index-1+buttons.length)%buttons.length; if (event.key==='Home') next=0; if(event.key==='End') next=buttons.length-1; if(next!==undefined) { event.preventDefault(); select(buttons[next],true); } }); });
  }
  bindTabs('data-query', button => { selectedQuery=button.dataset.query; renderQuery(); }, 'search-results');
  bindTabs('data-session', button => { selectedSession=button.dataset.session; renderSession(); }, 'chat-panel');
  bindTabs('data-model', button => { selectedModel=button.dataset.model; renderModel(); }, 'model-panel');
  $$('[data-contact]').forEach(button => button.addEventListener('click', () => { selectedContact=button.dataset.contact; renderContact(); }));
  $$('[data-file]').forEach(button => button.addEventListener('click', () => {
    const files = {brief: [['项目清单', 'Project brief'], ['项目清单列出本次交付的材料、检查项和未确认内容。原始资料来自林佳的示例邮件。', 'The project brief lists delivery material, review items, and unconfirmed details. It comes from Jia Lin’s fictional message.']], budget: [['费用明细', 'Budget breakdown'], ['费用明细用于核对项目、日期与币种。对话可根据限定资料进行只读分析。', 'The budget breakdown helps check projects, dates, and currencies. Chat can analyze scoped material in a read-only environment.']], design: [['设计参考', 'Design reference'], ['设计参考与 Alex 的示例往来关联，可以预览并交给当前工作对话。', 'The design reference is linked to Alex’s fictional correspondence and can be previewed or brought into the current conversation.']]};
    const data=files[button.dataset.file]; currentFeature=null; populateDetail(t('虚构附件示例', 'Fictional attachment example'),pair(data[0]),pair(data[1]),[t('此页面不下载或读取真实附件。', 'This page does not download or read real attachments.')],'file','https://github.com/mapix/Morrow'); openDialog('feature-dialog');
  }));
  $('#chat-run').addEventListener('click', () => { $('#chat-result').textContent = pair(sessionData[selectedSession].result); $('#chat-result').hidden=false; });
  $$('[data-response]').forEach(button => button.addEventListener('click', () => { responseMode=button.dataset.response; $$('[data-response]').forEach(item=>item.setAttribute('aria-pressed',String(item===button))); renderResponse(); }));
  $('#rule-run').addEventListener('click', () => { $('#rule-result').classList.add('tested'); $('#rule-result').textContent = responseMode==='draft' ? t('示例匹配成功。已准备一份交付确认草稿，等待审阅。没有发送邮件。', 'Example matched. A delivery confirmation draft is ready for review. No email was sent.') : t('示例匹配成功。应用内须明确授权自动发送；本次网页试跑只展示匹配结果，没有发送邮件。', 'Example matched. Automatic sending requires explicit authorization in the app. This website test only shows the match; no email was sent.'); });
  $('#memory-pause').addEventListener('click', () => { memoryPaused=!memoryPaused; renderMemory(); $('#memory-status').textContent=memoryPaused?t('示例记忆已停用','Example memory paused'):t('示例记忆已恢复','Example memory resumed'); });
  $('#memory-edit').addEventListener('click', () => { $('#memory-input').value=customMemory||t('回复保持简短中文。','Keep replies brief and in English.'); openDialog('memory-dialog'); });
  $('#memory-form').addEventListener('submit', event => { event.preventDefault(); const value=$('#memory-input').value.trim(); if(!value) return; customMemory=value; renderMemory(); $('#memory-dialog').close(); $('#memory-edit').focus({preventScroll:true}); });
  $('#language-toggle').addEventListener('click', () => applyLanguage(language==='zh'?'en':'zh'));
  $('#preview-open').addEventListener('click', () => openDialog('preview-dialog'));
  function renderExpo() {
    const data=chapters[expoIndex]; $('#expo-number').textContent=String(expoIndex+1).padStart(2,'0')+' / 08'; $('#expo-title').textContent=pair(data[1]); $('#expo-description').textContent=pair(data[2]); $('#expo-icon use').setAttribute('href','#i-'+data[3]);
    $('#expo-dots').replaceChildren(...chapters.map((chapter,index) => { const button=element('button'); button.setAttribute('aria-label',pair(chapter[1])); button.setAttribute('aria-pressed',String(index===expoIndex)); button.addEventListener('click',()=>{expoIndex=index;renderExpo(); $('#expo-dots').children[index].focus();}); return button; }));
  }
  function moveExpo(delta) { const focusDots=$('#expo-dots').contains(document.activeElement); expoIndex=(expoIndex+delta+chapters.length)%chapters.length; renderExpo(); if(focusDots) $('#expo-dots').children[expoIndex].focus(); }
  $('#expo-open').addEventListener('click',()=>{ renderExpo(); openDialog('expo-dialog'); });
  $('#expo-prev').addEventListener('click',()=>moveExpo(-1)); $('#expo-next').addEventListener('click',()=>moveExpo(1));
  $('#expo-dialog').addEventListener('keydown', event=>{if(event.key==='ArrowRight'){event.preventDefault();moveExpo(1);}if(event.key==='ArrowLeft'){event.preventDefault();moveExpo(-1);}});
  $('#expo-detail').addEventListener('click',()=>{ $('#expo-dialog').close(); const target=document.getElementById(chapters[expoIndex][0]); target.scrollIntoView(); target.querySelector('h2').tabIndex=-1; target.querySelector('h2').focus({preventScroll:true}); });
  const safeURL = value => {
    if (typeof value !== 'string' || value.length > 2048) return null;
    try { const url = new URL(value,location.href); if (!url.username && !url.password && (url.protocol==='https:' || (value.startsWith('/') && url.origin===location.origin))) return url.href; } catch (_) { /* Keep the download unavailable. */ }
    return null;
  };
  function updateDownload() {
    const mac=downloadManifest?.macOS; const url=safeURL(mac?.url); $('#download-action').disabled=!url; $('#download-action').setAttribute('aria-busy',String(downloadState==='pending')); $('#download-retry').hidden=downloadState!=='unavailable';
    $('#download-status').textContent=url?t('公开版本下载信息已读取。','Public release information loaded.'):downloadState==='unavailable'?t('暂时无法读取下载信息。请在 GitHub 查看版本，或重试。','Download information is unavailable. Check GitHub releases or retry.'):t('正在读取公开版本信息。','Loading public release information.');
    const details=['macOS '+(typeof mac?.minimumVersion==='string'?mac.minimumVersion.slice(0,20):'26.0')+'+',typeof mac?.architecture==='string'?mac.architecture.slice(0,60):'Apple Silicon'];
    if(typeof downloadManifest?.version==='string') details.unshift('v'+downloadManifest.version.slice(0,60));
    const size=Number(mac?.sizeBytes); if(Number.isFinite(size)&&size>0) details.push(new Intl.NumberFormat(language==='zh'?'zh-Hans':'en',{maximumFractionDigits:1}).format(size/1048576)+' MB');
    $('#download-meta').textContent=details.join(' / '); $('#release-link').href=safeURL(downloadManifest?.releaseUrl)||'https://github.com/mapix/Morrow/releases';
    const sha=typeof mac?.sha256==='string'&&/^[a-f\d]{64}$/i.test(mac.sha256)?mac.sha256:''; $('#checksum').hidden=!sha; $('#checksum-value').textContent=sha?'SHA-256: '+sha:'';
  }
  async function readDownloadManifest() {
    const controller=new AbortController(); const timer=setTimeout(()=>controller.abort(),5000); downloadManifest=null;downloadState='pending'; $('#download-retry').disabled=true;updateDownload();
    try { const response=await fetch('/downloads/latest.json',{cache:'no-store',credentials:'omit',signal:controller.signal});if(!response.ok)throw new Error('Unavailable');const manifest=await response.json();if(manifest?.schemaVersion!==1||!manifest.macOS||!safeURL(manifest.macOS.url))throw new Error('Invalid');downloadManifest=manifest;downloadState='ready'; }
    catch (_) { downloadState='unavailable'; }
    finally { clearTimeout(timer);$('#download-retry').disabled=false;updateDownload(); }
  }
  $('#download-retry').addEventListener('click',readDownloadManifest);
  $('#download-action').addEventListener('click',()=>{const url=safeURL(downloadManifest?.macOS?.url);if(url)location.assign(url);});
  const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)');
  const canvas=$('#constellation'), ctx=canvas.getContext('2d'), universe=$('#universe');
  let width=0,height=0,canvasColors={},pointer={x:.5,y:.5},scenePointer={x:.5,y:.5},canvasVisible=false,frameId=0;
  const stars=Array.from({length:66},(_,index)=>({x:((index*73+31)%997)/997,y:((index*139+83)%991)/991,size:index%7===0?2:1,phase:index*.7}));
  function readCanvasColors() { const style=getComputedStyle(document.documentElement); canvasColors={line:style.getPropertyValue('--color-soft').trim(),point:style.getPropertyValue('--color-fg').trim(),highlight:style.getPropertyValue('--color-highlight').trim()}; }
  function resizeCanvas() {
    const bounds=universe.getBoundingClientRect();width=bounds.width;height=bounds.height;const dpr=Math.min(devicePixelRatio||1,2);canvas.width=Math.round(width*dpr);canvas.height=Math.round(height*dpr);ctx?.setTransform(dpr,0,0,dpr,0,0);drawCanvas(performance.now());
  }
  function drawCanvas(time) {
    if(!ctx||!width||!height)return;ctx.clearRect(0,0,width,height);
    scenePointer.x+=(pointer.x-scenePointer.x)*.09;scenePointer.y+=(pointer.y-scenePointer.y)*.09;
    const shiftX=reducedMotion.matches?0:(scenePointer.x-.5)*40,shiftY=reducedMotion.matches?0:(scenePointer.y-.5)*40;
    const center={x:width*.44+shiftX,y:height*.35+shiftY};
    const nodes=[{x:.17,y:.23},{x:.8,y:.19},{x:.82,y:.43},{x:.55,y:.74},{x:.2,y:.5},{x:.92,y:.75},{x:.72,y:.06},{x:.08,y:.68}];
    ctx.strokeStyle=canvasColors.line;ctx.lineWidth=.7;ctx.globalAlpha=.27;
    nodes.forEach((point,index)=>{const x=point.x*width,y=point.y*height;ctx.beginPath();ctx.moveTo(center.x,center.y);ctx.lineTo(x,y);ctx.stroke();ctx.beginPath();ctx.arc(x,y,index<5?4:2,0,Math.PI*2);ctx.stroke();});
    ctx.beginPath();ctx.ellipse(center.x,center.y,width*.27,height*.21,-.4,0,Math.PI*2);ctx.stroke();
    ctx.beginPath();ctx.ellipse(center.x,center.y,width*.18,height*.31,.5,0,Math.PI*2);ctx.stroke();
    ctx.fillStyle=canvasColors.point;stars.forEach(star=>{ctx.globalAlpha=reducedMotion.matches ? .3 : .12+(.5+.5*Math.sin(time*.0005+star.phase))*.3;ctx.fillRect(star.x*width+shiftX*.5,star.y*height+shiftY*.5,star.size,star.size);});
    if(!reducedMotion.matches) { ctx.fillStyle=canvasColors.highlight;ctx.globalAlpha=.8;nodes.slice(0,5).forEach((point,index)=>{const progress=(time*.00007+index*.2)%1;const x=center.x+(point.x*width-center.x)*progress,y=center.y+(point.y*height-center.y)*progress;ctx.beginPath();ctx.arc(x,y,1.5,0,Math.PI*2);ctx.fill();}); }
    ctx.globalAlpha=1;
  }
  function animate(time) { drawCanvas(time);frameId=canvasVisible&&!reducedMotion.matches&&!document.hidden?requestAnimationFrame(animate):0; }
  function startCanvas() { if(canvasVisible&&!reducedMotion.matches&&!document.hidden&&!frameId)frameId=requestAnimationFrame(animate);else drawCanvas(performance.now()); }
  if(ctx) { readCanvasColors();new ResizeObserver(resizeCanvas).observe(universe);new IntersectionObserver(entries=>{canvasVisible=entries[0].isIntersecting;if(!canvasVisible&&frameId){cancelAnimationFrame(frameId);frameId=0;}else startCanvas();},{threshold:0}).observe(universe);universe.addEventListener('pointermove',event=>{const rect=universe.getBoundingClientRect();pointer={x:(event.clientX-rect.left)/rect.width,y:(event.clientY-rect.top)/rect.height};},{passive:true});universe.addEventListener('pointerleave',()=>{pointer={x:.5,y:.5};});reducedMotion.addEventListener('change',()=>{if(frameId){cancelAnimationFrame(frameId);frameId=0;}startCanvas();}); }
  document.addEventListener('visibilitychange',()=>{if(document.hidden&&frameId){cancelAnimationFrame(frameId);frameId=0;}else startCanvas();});
  function applyTheme(theme) {
    document.documentElement.dataset.theme=['blue','pink','orange'].includes(theme)?theme:'blue';$$('[data-theme-choice]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.themeChoice===theme)));if(ctx){readCanvasColors();drawCanvas(performance.now());}
    try {localStorage.setItem('morrow-theme',theme);} catch (_) { /* Storage is optional. */ }
  }
  $$('[data-theme-choice]').forEach(button=>button.addEventListener('click',()=>applyTheme(button.dataset.themeChoice)));
  const headingObserver=new IntersectionObserver(entries=>{entries.forEach(entry=>{if(entry.isIntersecting){entry.target.classList.add('is-visible');entry.target.classList.remove('is-waiting');headingObserver.unobserve(entry.target);}});},{threshold:.2});
  $$('.chapter-heading').forEach(heading=>{if(!reducedMotion.matches)heading.classList.add('is-waiting');headingObserver.observe(heading);});
  let scrollScheduled=false;
  function updateReading() {
    scrollScheduled=false;let active='mail';const line=innerHeight*.4;
    $$('.chapter').forEach(chapter=>{if(chapter.getBoundingClientRect().top<=line)active=chapter.id;});
    const stage=scrollY<$('.hero').offsetHeight*.75?'hero':active;
    if(document.documentElement.dataset.stage!==stage){document.documentElement.dataset.stage=stage;if(ctx){readCanvasColors();drawCanvas(performance.now());}}
    $$('[data-chapter]').forEach(link=>{if(link.dataset.chapter===active)link.setAttribute('aria-current','location');else link.removeAttribute('aria-current');});
    const max=document.documentElement.scrollHeight-innerHeight;$('#reading-progress').style.transform='scaleX('+Math.max(0,Math.min(1,scrollY/Math.max(1,max)))+')';
  }
  addEventListener('scroll',()=>{if(!scrollScheduled){scrollScheduled=true;requestAnimationFrame(updateReading);}},{passive:true});
  let preferredLanguage='zh',preferredTheme='blue';
  try {preferredLanguage=new URLSearchParams(location.search).get('lang')||localStorage.getItem('morrow-language')||'zh';preferredTheme=localStorage.getItem('morrow-theme')||'blue';}catch(_){/* Keep defaults. */}
  applyLanguage(preferredLanguage);applyTheme(preferredTheme);updateReading();readDownloadManifest();
})();
