(() => {
  'use strict';
  const translations = {
    zh: {
      skip: '跳到内容', navigation: '主导航', home: 'Morrow 首页', navStory: '看它如何接下工作', source: '查看源码',
      heroTitle: '邮件里的事，<br>交给 Morrow。', heroLead: '它读懂来信，串起往来，把下一步带回你面前。', getMac: '获取 macOS 版', tryStory: '试试这件事', heroAlt: 'Morrow 的折叠信件品牌图形', requirements: '运行条件', platformNative: 'Swift 原生，留在你的桌面工作流里。', platformSource: '为 Mac 打造，源码开放。',
      storyTitle: '从一封来信，<br>到一件办好的事。', storyLead: '你给目的，Morrow 带着依据准备下一步。', storyTabs: '交互演示阶段', sceneRead: '读懂来信', scenePrepare: '准备回复', sceneFollow: '继续跟进', sampleSubject: '周五前，核对交付材料', from: '来自', sampleSender: '林佳，示例项目组', attachment: '附件', sampleFile: '交付清单.pdf', sampleBody: '请核对材料清单。缺少的内容，请在周五前告诉我。', readResultTitle: '先把该做的事找出来。', readResult: '需要核对附件，再回复缺项。Morrow 将这封邮件和相关往来放在同一范围。', readSettled: '依据随手可查', delegateTitle: '“替我核对，准备一封回复。”', delegateResult: '委托包含目的、范围和完成条件。你可以修改工作约定，再让它继续。', draftTitle: '给林佳的回复草稿', draftBody: '我会先核对清单与已收到的材料，再把缺项整理给你。尚未确认的内容会单独标出。', draftSettled: '可编辑，待你决定', followSubject: '林佳补充了新版清单', followBody: 'Morrow 将新来信归入这件工作，更新缺项说明，并保留上一版依据。', followSettled: '同一件事，继续推进', followResultTitle: '你不用重新讲一遍。', followResult: '持续委托保留工作状态。邮件变化后，新的分析和回复建议会回到原来的工作里。', simulation: '交互演示使用虚构邮件与固定示例，不会读取邮箱或发送邮件。',
      peopleTitle: '往来按人串起，<br>资料不再散落。', peopleLead: '历史邮件构建联系人档案；附件有自己的统一入口。', profileName: '联系人 Profile', profileText: '名字、往来、参与项目和可核验的线索，连接到原邮件。', attachmentName: '一个附件视图', attachmentText: '按文件类型与来源查找，预览、保存，再交给 Morrow 分析。', searchName: '用意思查邮件', searchText: '本机向量索引支持语义查询，也可以选择关键词检索。', relationPerson: '林佳', relationProject: '示例项目：交付材料', relationMail: '往来邮件', relationAttachment: '相关附件', relationEvidence: '线索依据',
      chatTitle: '一个伙伴，<br>不止一段对话。', chatLead: 'Chat 跟随你正在看的邮件、联系人、附件或草稿。', sessionTabs: '示例对话', sessionDelivery: '交付材料', sessionBilling: '账单整理', sessionPlanning: '周计划', deliveryDescription: '这段对话保留它的输入、文件和范围。切换到别的工作，再回来继续。', billingDescription: '把账单核对留在自己的会话里。已有的材料和输入，切换后仍然保留。', planningDescription: '另开一段对话整理周计划。固定范围，或让 Chat 跟随左侧的内容。', richInput: '带上你手里的内容', richInputText: '文件、截图、图片和语音，都进入同一个输入框。', structuredInput: '需要选择时，给你结构化交互', structuredInputText: '用表单、选项和表格完善约定，接着在原生界面里工作。',
      authorityTitle: '记得住，<br>也由你决定。', authorityLead: '让偏好延续，把自动响应的边界说清楚。', memoryName: '能管理的长期记忆', memoryText: '查看来源、范围与历史版本。确认、修改、停用或忘记，都有入口。', memoryExampleName: '示例偏好', memoryExampleText: '回复保持简短中文', memoryExampleScope: '作用范围', memoryExampleGlobal: '由你设置', responderName: '按条件响应新邮件', responderText: '设定邮箱、发件人和内容条件。先试跑，再选择准备草稿或自动回复。', responseChoices: '响应方式演示', draftOption: '只准备草稿', autoOption: '自动响应', draftNotice: '示例选择：准备后由你审阅。', autoNotice: '示例选择：在应用内明确设置条件与权限。此页面不会发送邮件。', privacyLocal: '向量索引留在本机。', privacyModel: '邮件内容交给你选择的模型服务。', privacyCloud: 'iCloud 同步可选，默认关闭。',
      downloadTitle: '把下一步，<br>留给 Morrow。', downloadLead: '从你自己的邮箱开始，慢慢建立共同的工作方式。', downloadMac: '下载 macOS 版', downloadPending: '下载清单尚未发布。可前往 GitHub 查看版本。', downloadUnavailable: '暂时无法读取下载清单。请在 GitHub 查看版本，或稍后重试。', downloadReady: 'macOS 下载已准备。', releases: '查看 GitHub 版本', verifyDownload: '验证下载文件', feedback: '反馈问题', footerDescription: '原生 AI 邮件伙伴。<br>网站示例全部虚构。', title: 'Morrow：把邮件里的事，交给伙伴', description: 'Morrow 是原生 AI 邮件伙伴：读取来信、串起联系人、管理附件与记忆，并按你的委托准备下一步。'
    },
    en: {
      skip: 'Skip to content', navigation: 'Main navigation', home: 'Morrow home', navStory: 'See a task unfold', source: 'View source', heroTitle: 'Delegate what<br>comes after email.', heroLead: 'A native partner that reads, remembers, and prepares your next move.', getMac: 'Get Morrow for macOS', tryStory: 'Try this task', heroAlt: 'Morrow folded correspondence brand artwork', requirements: 'System requirements', platformNative: 'Native Swift, within your desktop workflow.', platformSource: 'Built for Mac. Open source.',
      storyTitle: 'From an email<br>to work in motion.', storyLead: 'You set the goal. Morrow brings the next move, with evidence.', storyTabs: 'Interactive demonstration stages', sceneRead: 'Understand', scenePrepare: 'Prepare a reply', sceneFollow: 'Keep following', sampleSubject: 'Check delivery materials by Friday', from: 'From', sampleSender: 'Lin, fictional project team', attachment: 'Attachment', sampleFile: 'Delivery checklist.pdf', sampleBody: 'Please review the materials. Let me know what is missing by Friday.', readResultTitle: 'Find what needs doing first.', readResult: 'Review the attachment, then reply with the gaps. This email and related correspondence share one scope.', readSettled: 'Evidence within reach', delegateTitle: '“Check this and prepare a reply.”', delegateResult: 'A delegation holds a goal, scope, and completion condition. Edit the agreement before continuing.', draftTitle: 'A reply draft for Lin', draftBody: 'I will compare the checklist with the materials received, then summarize the gaps. Unconfirmed items will be marked separately.', draftSettled: 'Editable, for your decision', followSubject: 'Lin adds a revised checklist', followBody: 'Morrow connects the new email to this task, updates the gaps, and retains the previous evidence.', followSettled: 'The same task continues', followResultTitle: 'No need to explain it again.', followResult: 'Ongoing delegations retain their state. New analysis and reply suggestions return to the original work.', simulation: 'This interactive demonstration uses fictional emails and fixed examples. It does not read or send mail.',
      peopleTitle: 'Correspondence connects.<br>Materials stay in reach.', peopleLead: 'Mail history builds contact profiles. Attachments have one place of their own.', profileName: 'Contact profiles', profileText: 'Names, correspondence, projects, and verifiable clues connect to their source emails.', attachmentName: 'One attachment view', attachmentText: 'Find files by type and source. Preview, save, and ask Morrow to analyze them.', searchName: 'Search by meaning', searchText: 'Local vector indexing supports semantic queries. Keyword search remains available.', relationPerson: 'Lin', relationProject: 'Fictional project: delivery materials', relationMail: 'Correspondence', relationAttachment: 'Related files', relationEvidence: 'Source evidence',
      chatTitle: 'One partner.<br>More than one conversation.', chatLead: 'Chat follows the email, contact, attachment, or draft you are viewing.', sessionTabs: 'Example conversations', sessionDelivery: 'Delivery', sessionBilling: 'Invoices', sessionPlanning: 'Weekly plan', deliveryDescription: 'This conversation keeps its input, files, and scope. Switch to other work and return to continue.', billingDescription: 'Keep invoice checks in their own conversation. Its materials and input remain when you switch.', planningDescription: 'Open another conversation for the weekly plan. Pin a scope or let Chat follow your current view.', richInput: 'Bring what you have', richInputText: 'Files, screenshots, images, and voice share one input.', structuredInput: 'Make choices through structured interaction', structuredInputText: 'Forms, options, and tables help refine the agreement, then continue in the native app.',
      authorityTitle: 'It remembers.<br>You decide the boundaries.', authorityLead: 'Carry your preferences forward. Define how new mail gets a response.', memoryName: 'Memory you can manage', memoryText: 'Inspect sources, scope, and versions. Confirm, edit, pause, or forget.', memoryExampleName: 'Example preference', memoryExampleText: 'Keep replies brief', memoryExampleScope: 'Scope', memoryExampleGlobal: 'Defined by you', responderName: 'Respond to matching mail', responderText: 'Set the mailbox, sender, and content conditions. Preview before choosing drafts or automatic replies.', responseChoices: 'Example response mode', draftOption: 'Prepare drafts', autoOption: 'Respond automatically', draftNotice: 'Example choice: prepare a draft for your review.', autoNotice: 'Example choice: explicitly configure conditions and authority in the app. This page does not send mail.', privacyLocal: 'Vector indexing stays on your device.', privacyModel: 'Mail goes to the model service you select.', privacyCloud: 'Optional iCloud sync starts off.',
      downloadTitle: 'Leave the next move<br>with Morrow.', downloadLead: 'Start with your own mailbox and build a shared way of working.', downloadMac: 'Download for macOS', downloadPending: 'The download manifest is not published yet. View releases on GitHub.', downloadUnavailable: 'The download manifest is unavailable. Check GitHub releases or try again later.', downloadReady: 'The macOS download is ready.', releases: 'View GitHub releases', verifyDownload: 'Verify the download', feedback: 'Report an issue', footerDescription: 'Native AI mail partner.<br>All website examples are fictional.', title: 'Morrow: delegate what comes after email', description: 'Morrow is a native AI mail partner that reads incoming mail, connects contacts, manages attachments and memory, and prepares your next move.'
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
      if (url.protocol === 'https:' || (value.startsWith('/') && url.origin === location.origin)) return url.href;
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
    document.querySelector('.hero-actions .button-primary').href = url || '#download';
    button.removeAttribute('aria-busy');
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
  fetch('/downloads/latest.json', {cache: 'no-store', credentials: 'omit'})
    .then(response => { if (!response.ok) throw new Error('manifest unavailable'); return response.json(); })
    .then(manifest => { if (manifest?.schemaVersion !== 1 || typeof manifest.macOS !== 'object') throw new Error('manifest invalid'); downloadManifest = manifest; downloadState = 'ready'; updateDownload(); })
    .catch(() => { downloadState = 'unavailable'; updateDownload(); });
})();
