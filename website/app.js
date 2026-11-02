(() => {
  'use strict';
  const translations = {
  "zh": {
    "skip": "跳到内容",
    "navigation": "主导航",
    "home": "Morrow 首页",
    "navStory": "工作示例",
    "source": "源码",
    "heroTitle": "邮件、资料与后续工作。",
    "heroLead": "Morrow 是为 Mac 打造的邮件工作台。检索往来、查看附件、准备回复，并按明确范围使用 AI 辅助工作。",
    "getMac": "查看 macOS 下载",
    "tryStory": "查看工作示例",
    "previewLabel": "原生邮件界面",
    "previewOpen": "放大查看原生邮件界面",
    "previewAlt": "Morrow 原生邮件工作台：左侧邮件导航，中间原文与附件，右侧对话和来源。全部内容均为虚构示例。",
    "previewCaption": "当前原生界面 · 邮件原文、附件与辅助对话 · 虚构示例",
    "previewExpand": "放大查看",
    "requirements": "运行条件",
    "platformNative": "为 Mac 打造的原生应用。",
    "platformSource": "查看项目与公开版本。",
    "storyTitle": "从来信到回复",
    "storyLead": "用一组固定示例说明如何核对资料、准备草稿和继续跟进。",
    "storyTabs": "虚构工作示例阶段",
    "sceneRead": "核对来信",
    "scenePrepare": "准备草稿",
    "sceneFollow": "持续跟进",
    "sampleSubject": "周五前，核对交付材料",
    "from": "来自",
    "sampleSender": "林佳，示例项目组",
    "attachment": "附件",
    "sampleFile": "交付清单.pdf",
    "sampleBody": "请核对材料清单。缺少的内容，请在周五前告诉我。",
    "readResultTitle": "待办与来源",
    "readResult": "核对附件清单，标出缺项，再准备回复。原邮件与相关往来保留为核验依据。",
    "readSettled": "保留原邮件引用",
    "delegateTitle": "明确工作约定",
    "delegateResult": "指定目的、资料范围和完成条件。修改约定后再继续。",
    "draftTitle": "给林佳的回复草稿",
    "draftBody": "我会先核对清单与已收到的材料，再把缺项整理给你。尚未确认的内容会单独标出。",
    "draftSettled": "草稿尚未发送",
    "followSubject": "林佳补充了新版清单",
    "followBody": "Morrow 将新来信归入这件工作，更新缺项说明，并保留上一版依据。",
    "followSettled": "同一件事，继续推进",
    "followResultTitle": "保留原来的工作记录",
    "followResult": "持续委托保留状态、原始依据与历史版本。新邮件到达后可继续更新结果。",
    "simulation": "交互演示使用虚构邮件与固定示例，不会读取邮箱或发送邮件。",
    "peopleTitle": "联系人与原始资料",
    "peopleLead": "从往来记录查看联系人，在统一入口查找和预览附件。",
    "profileName": "联系人档案",
    "profileText": "查看历史往来与可核验线索，跳转原邮件确认。",
    "attachmentName": "附件管理",
    "attachmentText": "按文件类型与来源查找，预览、保存，再交给 Morrow 分析。",
    "searchName": "邮件检索",
    "searchText": "本机向量索引支持语义查询，也可以选择关键词检索。",
    "relationPerson": "林佳",
    "relationProject": "示例项目：交付材料",
    "relationMail": "往来邮件",
    "relationAttachment": "相关附件",
    "relationEvidence": "线索依据",
    "chatTitle": "按工作保留对话",
    "chatLead": "分别处理不同工作，输入、资料和上下文随会话保留。",
    "sessionTabs": "示例对话",
    "sessionDelivery": "交付材料",
    "sessionBilling": "账单整理",
    "sessionPlanning": "周计划",
    "deliveryDescription": "这段对话保留它的输入、文件和范围。切换到别的工作，再回来继续。",
    "billingDescription": "把账单核对留在自己的会话里。已有的材料和输入，切换后仍然保留。",
    "planningDescription": "另开一段对话整理周计划。固定范围，或让 Chat 跟随左侧的内容。",
    "richInput": "文件与输入",
    "richInputText": "支持文字、文件、截图、图片与语音输入。",
    "structuredInput": "结构化选择",
    "structuredInputText": "在表单、选项和表格中补充要求，再继续原生工作。",
    "authorityTitle": "记忆与自动响应",
    "authorityLead": "查看已保存的内容，并明确自动处理邮件的条件与权限。",
    "memoryName": "长期记忆",
    "memoryText": "查看来源、范围与历史版本。确认、修改、停用或忘记，都有入口。",
    "memoryExampleName": "示例偏好",
    "memoryExampleText": "回复保持简短中文",
    "memoryExampleScope": "作用范围",
    "memoryExampleGlobal": "由你设置",
    "responderName": "自动响应规则",
    "responderText": "限定邮箱、文件夹、发件人和内容条件。先试跑，自动发送需要显式授权。",
    "responseChoices": "响应方式演示",
    "draftOption": "只准备草稿",
    "autoOption": "自动响应",
    "draftNotice": "示例选择：准备后由你审阅。",
    "autoNotice": "示例选择：在应用内明确设置条件与权限。此页面不会发送邮件。",
    "privacyLocal": "向量索引留在本机。",
    "privacyModel": "邮件内容交给你选择的模型服务。",
    "privacyCloud": "iCloud 同步可选，默认关闭。",
    "downloadTitle": "下载公开版本",
    "downloadLead": "检查系统要求、公开版本说明与文件校验信息。",
    "downloadMac": "下载 macOS 公开版",
    "downloadPending": "正在读取公开版本信息。",
    "downloadUnavailable": "暂时无法读取下载清单。请在 GitHub 查看版本，或稍后重试。",
    "downloadReady": "公开版本下载信息已读取。",
    "releases": "查看 GitHub 版本",
    "verifyDownload": "验证下载文件",
    "feedback": "反馈问题",
    "footerDescription": "Mac 邮件工作台。<br>网站交互均使用固定虚构示例。",
    "title": "Morrow：Mac 邮件工作台",
    "description": "Morrow 是为 Mac 打造的邮件工作台，提供邮件检索、联系人与附件管理，以及可配置的 AI 辅助工作。",
    "navFeatures": "功能",
    "navDownload": "下载",
    "releaseBoundary": "本站展示当前项目界面。公开下载版本与功能以发布说明为准。",
    "factsTitle": "为桌面邮件工作设计",
    "factsPlatform": "运行平台",
    "factsMail": "邮件协议",
    "factsPOP": "兼容 POP3 接收",
    "factsModels": "模型选择",
    "factsModelsText": "本机模型或自选服务",
    "factsSource": "项目源码",
    "viewRepository": "查看 GitHub 仓库",
    "featuresTitle": "邮件工作中的常用能力",
    "featuresLead": "邮件和原始资料是主体，辅助功能按你的选择使用。",
    "mailFeatureTitle": "邮件与回复",
    "mailFeatureText": "连接邮箱、查找邮件、阅读原文，编辑与预览回复草稿。",
    "mailFeatureSearch": "语义、关键词与条件检索",
    "mailFeatureFolders": "收件、草稿与已发送记录",
    "mailFeatureReply": "回复、转发与附件",
    "materialFeatureTitle": "联系人与资料",
    "materialFeatureText": "从往来记录找到联系人和附件，结论保留原邮件依据。",
    "materialFeatureContacts": "联系人往来与可核验线索",
    "materialFeatureAttachments": "附件类型、来源与原件预览",
    "materialFeatureNotes": "简报、笔记与标签",
    "workFeatureTitle": "可配置的 AI 辅助",
    "workFeatureText": "为整理、回复与持续跟进指定范围，查看执行过程与结果。",
    "workFeatureSessions": "独立对话与工作上下文",
    "workFeatureMemory": "有来源与范围的长期记忆",
    "workFeatureRules": "有边界的自动响应规则",
    "retryDownload": "重新读取下载信息"
  },
  "en": {
    "skip": "Skip to content",
    "navigation": "Main navigation",
    "home": "Morrow home",
    "navStory": "Examples",
    "source": "Source",
    "heroTitle": "Email, materials, and the work that follows.",
    "heroLead": "Morrow is an email workspace for Mac. Search correspondence, inspect attachments, prepare replies, and use AI assistance within a defined scope.",
    "getMac": "View macOS downloads",
    "tryStory": "Explore the examples",
    "previewLabel": "Native email interface",
    "previewOpen": "View the native email interface at full size",
    "previewAlt": "Morrow's native email workspace with navigation on the left, original email and attachments in the center, and chat with sources on the right. All content is fictional.",
    "previewCaption": "Current native interface · Original mail, attachments, and chat · Fictional example",
    "previewExpand": "View full size",
    "requirements": "System requirements",
    "platformNative": "A native application built for Mac.",
    "platformSource": "Explore the project and public releases.",
    "storyTitle": "From incoming mail to a reply",
    "storyLead": "A fixed example shows how to check materials, prepare a draft, and continue the task.",
    "storyTabs": "Fictional work example stages",
    "sceneRead": "Check the email",
    "scenePrepare": "Prepare a draft",
    "sceneFollow": "Continue follow-up",
    "sampleSubject": "Check delivery materials by Friday",
    "from": "From",
    "sampleSender": "Lin, fictional project team",
    "attachment": "Attachment",
    "sampleFile": "Delivery checklist.pdf",
    "sampleBody": "Please review the materials. Let me know what is missing by Friday.",
    "readResultTitle": "Task and source evidence",
    "readResult": "Compare the attachment list, identify gaps, and prepare a reply. Original mail and related correspondence remain available for verification.",
    "readSettled": "Original email citations retained",
    "delegateTitle": "Define the work agreement",
    "delegateResult": "Specify the goal, available materials, and completion criteria before continuing.",
    "draftTitle": "A reply draft for Lin",
    "draftBody": "I will compare the checklist with the materials received, then summarize the gaps. Unconfirmed items will be marked separately.",
    "draftSettled": "This draft has not been sent",
    "followSubject": "Lin adds a revised checklist",
    "followBody": "Morrow connects the new email to this task, updates the gaps, and retains the previous evidence.",
    "followSettled": "The same task continues",
    "followResultTitle": "Keep the original work record",
    "followResult": "Ongoing delegations retain state, source evidence, and revisions. New mail can update the same work.",
    "simulation": "This interactive demonstration uses fictional emails and fixed examples. It does not read or send mail.",
    "peopleTitle": "Contacts and original materials",
    "peopleLead": "Inspect people through correspondence and find attachments in one place.",
    "profileName": "Contact profiles",
    "profileText": "Inspect correspondence and verifiable clues, then open the original email.",
    "attachmentName": "Attachment management",
    "attachmentText": "Find files by type and source. Preview, save, and ask Morrow to analyze them.",
    "searchName": "Mail search",
    "searchText": "Local vector indexing supports semantic queries. Keyword search remains available.",
    "relationPerson": "Lin",
    "relationProject": "Fictional project: delivery materials",
    "relationMail": "Correspondence",
    "relationAttachment": "Related files",
    "relationEvidence": "Source evidence",
    "chatTitle": "Separate conversations for separate work",
    "chatLead": "Inputs, materials, and context remain with each conversation.",
    "sessionTabs": "Example conversations",
    "sessionDelivery": "Delivery",
    "sessionBilling": "Invoices",
    "sessionPlanning": "Weekly plan",
    "deliveryDescription": "This conversation keeps its input, files, and scope. Switch to other work and return to continue.",
    "billingDescription": "Keep invoice checks in their own conversation. Its materials and input remain when you switch.",
    "planningDescription": "Open another conversation for the weekly plan. Pin a scope or let Chat follow your current view.",
    "richInput": "Files and input",
    "richInputText": "Text, files, screenshots, images, and voice input are supported.",
    "structuredInput": "Structured choices",
    "structuredInputText": "Refine requirements through forms, options, and tables, then continue in the native app.",
    "authorityTitle": "Memory and automatic responses",
    "authorityLead": "Inspect saved information and define the conditions and authority for mail processing.",
    "memoryName": "Long-term memory",
    "memoryText": "Inspect sources, scope, and versions. Confirm, edit, pause, or forget.",
    "memoryExampleName": "Example preference",
    "memoryExampleText": "Keep replies brief",
    "memoryExampleScope": "Scope",
    "memoryExampleGlobal": "Defined by you",
    "responderName": "Automatic response rules",
    "responderText": "Set the mailbox, folder, sender, and content conditions. Test first; automatic sending requires explicit authority.",
    "responseChoices": "Example response mode",
    "draftOption": "Prepare drafts",
    "autoOption": "Respond automatically",
    "draftNotice": "Example choice: prepare a draft for your review.",
    "autoNotice": "Example choice: explicitly configure conditions and authority in the app. This page does not send mail.",
    "privacyLocal": "Vector indexing stays on your device.",
    "privacyModel": "Mail goes to the model service you select.",
    "privacyCloud": "Optional iCloud sync starts off.",
    "downloadTitle": "Download a public release",
    "downloadLead": "Check system requirements, release notes, and file verification details.",
    "downloadMac": "Download the macOS public release",
    "downloadPending": "Loading public release information.",
    "downloadUnavailable": "The download manifest is unavailable. Check GitHub releases or try again later.",
    "downloadReady": "Public release download information is available.",
    "releases": "View GitHub releases",
    "verifyDownload": "Verify the download",
    "feedback": "Report an issue",
    "footerDescription": "An email workspace for Mac.<br>Website interactions use fixed fictional examples.",
    "title": "Morrow: an email workspace for Mac",
    "description": "Morrow is an email workspace for Mac with mail search, contact and attachment management, and configurable AI assistance.",
    "navFeatures": "Features",
    "navDownload": "Download",
    "releaseBoundary": "This site shows the current project interface. Public downloads and features are defined by their release notes.",
    "factsTitle": "Designed for desktop email",
    "factsPlatform": "Platform",
    "factsMail": "Mail protocols",
    "factsPOP": "POP3 receiving supported",
    "factsModels": "Models",
    "factsModelsText": "Local models or a service you choose",
    "factsSource": "Source code",
    "viewRepository": "View the GitHub repository",
    "featuresTitle": "The essentials of email work",
    "featuresLead": "Email and original materials stay central. Choose the assistance you need.",
    "mailFeatureTitle": "Email and replies",
    "mailFeatureText": "Connect accounts, search mail, read original messages, and edit or preview reply drafts.",
    "mailFeatureSearch": "Semantic, keyword, and condition search",
    "mailFeatureFolders": "Inbox, drafts, and sent records",
    "mailFeatureReply": "Replies, forwarding, and attachments",
    "materialFeatureTitle": "Contacts and materials",
    "materialFeatureText": "Find people and files through correspondence. Conclusions retain their original email sources.",
    "materialFeatureContacts": "Correspondence and verifiable contact clues",
    "materialFeatureAttachments": "Attachment types, sources, and original previews",
    "materialFeatureNotes": "Reports, notes, and labels",
    "workFeatureTitle": "Configurable AI assistance",
    "workFeatureText": "Define a scope for organization, replies, and follow-up. Inspect the process and results.",
    "workFeatureSessions": "Separate conversations and work context",
    "workFeatureMemory": "Memory with sources and scope",
    "workFeatureRules": "Bounded automatic response rules",
    "retryDownload": "Reload download information"
  }
};
  let language = 'zh';
  let selectedSession = 'delivery';
  let responseMode = 'draft';
  let downloadManifest = null;
  let downloadState = 'pending';
  const sessions = {delivery: ['sessionDelivery', 'deliveryDescription'], billing: ['sessionBilling', 'billingDescription'], planning: ['sessionPlanning', 'planningDescription']};
  const text = key => translations[language][key] || translations.zh[key] || key;
  const safeURL = value => {
    if (typeof value !== 'string' || value.length > 2048) return null;
    try {
      const url = new URL(value, location.href);
      if (!url.username && !url.password && (url.protocol === 'https:' || (value.startsWith('/') && url.origin === location.origin))) return url.href;
    } catch (_) { /* Invalid manifests leave the fallback link available. */ }
    return null;
  };
  function updateSession() {
    document.getElementById('session-heading').textContent = text(sessions[selectedSession][0]);
    document.getElementById('session-description').textContent = text(sessions[selectedSession][1]);
  }
  function updateResponse() { document.getElementById('response-status').textContent = text(responseMode === 'draft' ? 'draftNotice' : 'autoNotice'); }
  function updateDownload() {
    const button = document.getElementById('download-action');
    const status = document.getElementById('download-status');
    const mac = downloadManifest?.macOS;
    const url = safeURL(mac?.url);
    button.disabled = !url;
    document.querySelector('.hero-actions .button-primary').href = '#download';
    document.getElementById('download-retry').hidden = downloadState !== 'unavailable';
    button.setAttribute('aria-busy', String(downloadState === 'pending'));
    status.textContent = text(url ? 'downloadReady' : downloadState === 'unavailable' ? 'downloadUnavailable' : 'downloadPending');
    const version = typeof downloadManifest?.version === 'string' ? downloadManifest.version.slice(0, 60) : '';
    const size = Number(mac?.sizeBytes);
    const details = ['macOS ' + (mac?.minimumVersion || '26.0') + '+', mac?.architecture || 'Apple Silicon'];
    if (version) details.unshift(version);
    if (Number.isFinite(size) && size > 0) details.push(new Intl.NumberFormat(language === 'zh' ? 'zh-Hans' : 'en', {maximumFractionDigits: 1}).format(size / 1048576) + ' MB');
    document.getElementById('download-meta').textContent = details.join(' / ');
    document.getElementById('release-link').href = safeURL(downloadManifest?.releaseUrl) || 'https://github.com/mapix/Morrow/releases';
    const sha = typeof mac?.sha256 === 'string' && /^[a-f\d]{64}$/i.test(mac.sha256) ? mac.sha256 : '';
    document.getElementById('checksum').hidden = !sha;
    document.getElementById('checksum-value').textContent = sha ? 'SHA-256: ' + sha : '';
  }
  function setLanguage(next) {
    language = next === 'en' ? 'en' : 'zh';
    document.documentElement.lang = language === 'zh' ? 'zh-Hans' : 'en';
    document.querySelectorAll('[data-i18n]').forEach(element => { element.innerHTML = text(element.dataset.i18n); });
    document.querySelectorAll('[data-i18n-aria]').forEach(element => { element.setAttribute('aria-label', text(element.dataset.i18nAria)); });
    document.querySelectorAll('[data-i18n-alt]').forEach(element => { element.alt = text(element.dataset.i18nAlt); });
    document.querySelectorAll('[data-language]').forEach(button => { button.setAttribute('aria-pressed', String(button.dataset.language === language)); });
    document.title = text('title');
    document.querySelector('meta[name="description"]').content = text('description');
    document.querySelector('meta[property="og:title"]').content = text('title');
    document.querySelector('meta[property="og:description"]').content = text('description');
    try { localStorage.setItem('morrow-language', language); } catch (_) { /* Storage is optional. */ }
    updateSession(); updateResponse(); updateDownload();
  }
  function activateScene(name) {
    document.querySelectorAll('[data-scene]').forEach(button => { const selected = button.dataset.scene === name; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1; });
    document.querySelectorAll('.scene').forEach(panel => { panel.hidden = panel.id !== 'scene-' + name; });
  }
  function arrowNavigation(buttons, handler) {
    buttons.forEach((button, index) => button.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight' || event.key === 'ArrowDown') next = (index + 1) % buttons.length;
      if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') next = (index - 1 + buttons.length) % buttons.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = buttons.length - 1;
      if (next === undefined) return;
      event.preventDefault(); handler(buttons[next]); buttons[next].focus({preventScroll: true});
    }));
  }
  document.documentElement.classList.add('js');
  document.querySelectorAll('[data-language]').forEach(button => button.addEventListener('click', () => setLanguage(button.dataset.language)));
  const sceneButtons = [...document.querySelectorAll('[data-scene]')];
  sceneButtons.forEach(button => button.addEventListener('click', () => activateScene(button.dataset.scene)));
  arrowNavigation(sceneButtons, button => activateScene(button.dataset.scene));
  const sessionButtons = [...document.querySelectorAll('[data-session]')];
  const selectSession = button => {
    selectedSession = button.dataset.session;
    document.getElementById('conversation-panel').setAttribute('aria-labelledby', button.id);
    sessionButtons.forEach(item => { const selected = item === button; item.setAttribute('aria-selected', String(selected)); item.tabIndex = selected ? 0 : -1; });
    updateSession();
  };
  sessionButtons.forEach(button => button.addEventListener('click', () => selectSession(button)));
  arrowNavigation(sessionButtons, selectSession);
  document.querySelectorAll('[data-response]').forEach(button => button.addEventListener('click', () => {
    responseMode = button.dataset.response;
    document.querySelectorAll('[data-response]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    updateResponse();
  }));
  document.getElementById('download-action').addEventListener('click', () => { const url = safeURL(downloadManifest?.macOS?.url); if (url) location.assign(url); });
  document.querySelectorAll('[data-slot] > img, .brand img').forEach(image => { const removeBroken = () => image.remove(); if (image.complete && !image.naturalWidth) removeBroken(); else image.addEventListener('error', removeBroken, {once: true}); });
  activateScene('read'); selectSession(sessionButtons[0]);
  let preferred;
  try { preferred = new URLSearchParams(location.search).get('lang') || localStorage.getItem('morrow-language'); } catch (_) { /* Defaults remain readable. */ }
  setLanguage(preferred || (navigator.language.startsWith('zh') ? 'zh' : 'en'));
  async function readDownloadManifest() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    downloadState = 'pending'; downloadManifest = null;
    document.getElementById('download-action').setAttribute('aria-busy', 'true');
    document.getElementById('download-retry').disabled = true;
    updateDownload();
    try {
      const response = await fetch('/downloads/latest.json', {cache: 'no-store', credentials: 'omit', signal: controller.signal});
      if (!response.ok) throw new Error('manifest unavailable');
      const manifest = await response.json();
      if (manifest?.schemaVersion !== 1 || !manifest.macOS || typeof manifest.macOS !== 'object') throw new Error('manifest invalid');
      if (!safeURL(manifest.macOS.url)) throw new Error('download URL invalid');
      downloadManifest = manifest; downloadState = 'ready';
    } catch (_) { downloadState = 'unavailable'; }
    finally { clearTimeout(timer); document.getElementById('download-retry').disabled = false; updateDownload(); }
  }
  document.getElementById('download-retry').addEventListener('click', readDownloadManifest);
  readDownloadManifest();
})();
