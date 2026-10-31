import SwiftUI

@MainActor enum MobileL10n {
    static var language: String { UserDefaults.standard.string(forKey: "SmailMobileLanguage") ?? "zh-Hans" }
    static var responseLanguage: String { language == "en" ? "English" : language == "ja" ? "日本語" : "简体中文" }
    static func text(_ source: String) -> String {
        if language == "zh-Hans" { return source }
        let pair = values[source]; return language == "ja" ? pair?.1 ?? source : pair?.0 ?? source
    }
    static let values: [String: (String, String)] = [
        "关闭": ("Close", "閉じる"),
        "原始排版": ("Original layout", "元のレイアウト"),
        "外部图片已阻止": ("External images blocked", "外部画像をブロック済み"),
        "正文显示方式": ("Message display", "本文の表示"),
        "正文暂时无法显示，请稍后重试。": ("The message cannot be displayed right now. Try again.", "本文を表示できません。再試行してください。"),
        "此邮件没有可显示的纯文本正文。": ("This message has no plain-text body.", "このメールにはプレーンテキスト本文がありません。"),
        "纯文本": ("Plain text", "プレーンテキスト"),
        "邮件详情": ("Mail details", "メールの詳細"),
        "加载外部图片": ("Load external images", "外部画像を読み込む"),
        "阻止外部图片": ("Block external images", "外部画像をブロック"),
        "让往来的邮件，成为可委托的工作。": ("Turn correspondence into work you can delegate.", "メールのやり取りを、任せられる仕事に。"),
        "查找相关往来，拟定回复，整理附件，记住你的偏好。": ("Find conversations, prepare replies, organize files, remember your preferences.", "やり取りを探し、返信を準備し、添付ファイルや好みを整理します。"),
        "结构化交互无法显示，请用聊天继续。": ("This form is unavailable. Continue in Chat.", "このフォームは表示できません。チャットで続けてください。"),
        "ChatGPT 登录的手机回调方式尚未由服务商提供；可在 Mac 登录，手机使用本机模型或自有模型服务。": ("The provider has not published a mobile ChatGPT callback. Use on-device models or your model service here; ChatGPT login is available on Mac.", "ChatGPT のモバイル認証コールバックは未公開です。端末内モデルか自分のサービスを使用してください。Mac では ChatGPT ログインを利用できます。"),
        "未安装本机向量模型。语义检索会明确提示缺少索引，可切换关键词。": ("No vector model installed. Semantic search explains missing indexing; keyword search remains available.", "ベクトルモデルがありません。意味検索は索引の不足を明示します。キーワード検索は利用できます。"),
        "已选择本机模型文件夹": ("On-device model folder selected", "端末内モデルフォルダーを選択済み"),
        "iCloud 默认关闭；此安装尚未配置已签名的容器。": ("iCloud is off by default. This build has no signed container.", "iCloud は初期状態でオフです。このビルドには署名済みコンテナーがありません。"),
        "手机前台同步和处理邮件；持续响应与后台工作由 Mac 执行。账号凭据保存在本机钥匙串。": ("Mail sync and processing run in the foreground. Mac handles ongoing work. Credentials stay in this device's Keychain.", "メールの同期と処理は前面で動作します。継続する仕事は Mac が担当します。認証情報はこの端末のキーチェーンに保存します。"),
        "匹配的新邮件在前台同步后生成草稿。手机不接管 Mac 的自动发送权限。": ("Matching new mail creates drafts after foreground sync. Mac's automatic-send permission is not transferred.", "条件に一致する新着メールは同期後に下書きを作成します。Mac の自動送信権限は引き継ぎません。"),
        "工作": ("Work", "仕事"), "邮件": ("Mail", "メール"), "联系人": ("People", "連絡先"), "附件": ("Files", "添付ファイル"), "设置": ("Settings", "設定"), "委托给 Morrow": ("Delegate to Morrow", "Morrow に任せる"), "新对话": ("New chat", "新しい会話"), "对话": ("Chats", "会話"), "全部邮箱": ("All mailboxes", "すべてのメールボックス"), "搜索邮件": ("Search mail", "メール検索"), "语义": ("Semantic", "意味検索"), "关键词": ("Keyword", "キーワード"), "未读": ("Unread", "未読"), "已读": ("Read", "既読"), "待回复": ("Reply needed", "要返信"), "回复": ("Reply", "返信"), "标记已读": ("Mark read", "既読にする"), "标记未读": ("Mark unread", "未読にする"), "分析邮件": ("Analyze mail", "メールを分析"), "取消": ("Cancel", "キャンセル"), "完成": ("Done", "完了"), "保存": ("Save", "保存"), "发送": ("Send", "送信"), "发送这封邮件？": ("Send this email?", "このメールを送信しますか？"), "收件人": ("To", "宛先"), "抄送": ("Cc", "Cc"), "密送": ("Bcc", "Bcc"), "主题": ("Subject", "件名"), "正文": ("Message", "本文"), "发件邮箱": ("Send from", "差出人"), "草稿": ("Drafts", "下書き"), "保存草稿": ("Save draft", "下書きを保存"), "连接邮箱": ("Connect mailbox", "メールボックスを接続"), "演示工作区": ("Try the demo", "デモを試す"), "邮箱地址": ("Email address", "メールアドレス"), "授权码": ("App password", "アプリパスワード"), "邮箱名称": ("Mailbox name", "メールボックス名"), "接收服务器": ("Incoming server", "受信サーバー"), "发送服务器": ("SMTP server", "SMTP サーバー"), "接收端口": ("Incoming port", "受信ポート"), "发送端口": ("SMTP port", "SMTP ポート"), "测试并连接": ("Test and connect", "テストして接続"), "模型": ("Model", "モデル"), "模型服务": ("Model service", "モデルサービス"), "模型地址": ("Model URL", "モデル URL"), "模型名称": ("Model name", "モデル名"), "API Key": ("API Key", "API キー"), "本机模型": ("On-device model", "端末内モデル"), "导入模型文件夹": ("Import model folder", "モデルフォルダーを読み込む"), "重建索引": ("Update index", "索引を更新"), "外观": ("Appearance", "外観"), "语言": ("Language", "言語"), "主题配色": ("Theme", "テーマ"), "布局": ("Density", "表示密度"), "紧凑": ("Compact", "コンパクト"), "宽松": ("Comfortable", "ゆったり"), "记忆": ("Memory", "メモリー"), "响应器": ("Responders", "自動応答"), "归档": ("Archive", "アーカイブ"), "恢复": ("Restore", "復元"), "全部": ("All", "すべて"), "搜索对话": ("Search chats", "会話を検索"), "创建对话": ("Create chat", "会話を作成"), "给伙伴的委托": ("A task for your partner", "パートナーへの依頼"), "添加文件": ("Attach file", "ファイルを添付"), "选择截图或图片": ("Choose screenshot or photo", "スクリーンショット・写真を選択"), "语音输入": ("Voice input", "音声入力"), "结束语音": ("Stop recording", "録音を終了"), "添加记忆": ("Add memory", "メモリーを追加"), "记住偏好": ("Remember a preference", "好みを記憶する"), "暂停": ("Pause", "一時停止"), "启用": ("Enable", "有効にする"), "名字": ("Name", "名前"), "发件人条件": ("Sender condition", "差出人条件"), "主题包含": ("Subject contains", "件名に含まれる"), "回复内容": ("Reply text", "返信文"), "自动草稿": ("Automatic drafts", "下書きの自動作成"), "错误": ("Error", "エラー"), "未完成：": ("Not completed: ", "未完了："), "暂无邮件": ("No mail yet", "メールはまだありません"), "暂无附件": ("No attachments", "添付ファイルはありません"), "暂无联系人": ("No contacts yet", "連絡先はまだありません"), "暂无待办": ("Nothing needs attention", "対応が必要なものはありません"), "前台同步": ("Sync now", "今すぐ同期"), "导入邮件": ("Import email", "メールを読み込む"), "来源邮件": ("Source mail", "元のメール"), "忘记": ("Forget", "削除"), "自动分析新邮件": ("Analyze new mail", "新着メールを分析"), "分析附件": ("Analyze attachments", "添付ファイルを分析"), "固定当前上下文": ("Pin current context", "現在の文脈を固定")
    ]
}

struct MobilePalette {
    let paper: Color, sheet: Color, ink: Color, muted: Color, accent: Color, rule: Color, unread: Color
    static func value(_ name: String) -> MobilePalette {
        switch name {
        case "dark": return .init(paper: Color(red: 0.09, green: 0.10, blue: 0.12), sheet: Color(red: 0.13, green: 0.14, blue: 0.17), ink: Color(red: 0.96, green: 0.94, blue: 0.92), muted: Color(red: 0.70, green: 0.70, blue: 0.73), accent: Color(red: 1, green: 0.64, blue: 0.54), rule: Color(red: 0.30, green: 0.31, blue: 0.35), unread: Color(red: 0.26, green: 0.19, blue: 0.18))
        case "forest": return .init(paper: Color(red: 0.95, green: 0.96, blue: 0.92), sheet: Color(red: 0.99, green: 0.99, blue: 0.97), ink: Color(red: 0.12, green: 0.19, blue: 0.15), muted: Color(red: 0.37, green: 0.43, blue: 0.37), accent: Color(red: 0.22, green: 0.42, blue: 0.31), rule: Color(red: 0.78, green: 0.82, blue: 0.76), unread: Color(red: 0.86, green: 0.92, blue: 0.81))
        case "slate": return .init(paper: Color(red: 0.94, green: 0.95, blue: 0.97), sheet: .white, ink: Color(red: 0.11, green: 0.15, blue: 0.23), muted: Color(red: 0.36, green: 0.41, blue: 0.50), accent: Color(red: 0.20, green: 0.36, blue: 0.62), rule: Color(red: 0.79, green: 0.82, blue: 0.87), unread: Color(red: 0.85, green: 0.90, blue: 0.98))
        default: return .init(paper: Color(red: 0.974, green: 0.957, blue: 0.946), sheet: Color(red: 0.991, green: 0.983, blue: 0.971), ink: Color(red: 0.115, green: 0.088, blue: 0.080), muted: Color(red: 0.382, green: 0.348, blue: 0.333), accent: Color(red: 0.735, green: 0.237, blue: 0.191), rule: Color(red: 0.851, green: 0.826, blue: 0.811), unread: Color(red: 0.985, green: 0.892, blue: 0.861))
        }
    }
}
