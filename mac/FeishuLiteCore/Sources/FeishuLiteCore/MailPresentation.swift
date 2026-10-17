import Foundation

/// 邮件阅读器的排版常量。HTML 外壳 CSS、纯文本视图和邮件头部共用，两种正文看起来一致。
public enum MailReaderLayout {
    /// 头部和正文共用的左右边距
    public static let horizontalMargin: Double = 20
    /// 正文上下边距。纯文本的位置恢复按这个值换算
    public static let verticalMargin: Double = 20
    /// 正文最大阅读宽度（不含边距），14pt 下约 51 个汉字
    public static let maxReadingWidth: Double = 720
    public static let bodyFontSize: Double = 14
    public static let lineHeight: Double = 1.5
    /// 邮件主题字号（系统 title2）
    public static let subjectFontSize: Double = 17
    /// HTML h1–h3 的字号，都小于主题；h4–h6 与正文相同
    public static let headingFontSizes: [Double] = [16, 15, 14]
}

/// 文件夹菜单里的一项：只显示名字，按层级缩进。
public struct MailFolderMenuEntry: Equatable, Sendable, Identifiable {
    public var folder: MailFolder
    public var title: String
    public var depth: Int
    /// 本期只有收件箱能读取
    public var isReadable: Bool
    public var id: String { folder.id }
}

public enum MailFolderMenu {
    /// 收件箱在最前，子文件夹紧跟在父文件夹后面；同级保持服务器给出的顺序。
    public static func entries(_ folders: [MailFolder]) -> [MailFolderMenuEntry] {
        let ids = Set(folders.map(\.id))
        var children: [String: [MailFolder]] = [:]
        var roots: [MailFolder] = []
        for folder in folders {
            if let parent = parentID(of: folder, among: ids) {
                children[parent, default: []].append(folder)
            } else {
                roots.append(folder)
            }
        }
        if let inbox = roots.firstIndex(where: { $0.id == "INBOX" }) { roots.insert(roots.remove(at: inbox), at: 0) }
        var result: [MailFolderMenuEntry] = []
        func visit(_ folder: MailFolder, depth: Int) {
            result.append(MailFolderMenuEntry(folder: folder, title: title(of: folder), depth: depth,
                                              isReadable: folder.id == "INBOX" && folder.supported && folder.selectable))
            for child in children[folder.id] ?? [] { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return result
    }

    /// 菜单按钮上的文字：当前文件夹的名字
    public static func title(for folderID: String, in folders: [MailFolder]) -> String {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return "收件箱" }
        return title(of: folder)
    }

    private static func title(of folder: MailFolder) -> String {
        if !folder.name.isEmpty { return folder.name }
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return folder.id }
        return folder.id.components(separatedBy: delimiter).last ?? folder.id
    }

    /// 最近的、也在列表里的上级文件夹
    private static func parentID(of folder: MailFolder, among ids: Set<String>) -> String? {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return nil }
        var parts = folder.id.components(separatedBy: delimiter)
        while parts.count > 1 {
            parts.removeLast()
            let candidate = parts.joined(separator: delimiter)
            if ids.contains(candidate) { return candidate }
        }
        return nil
    }
}

extension MailAttachment {
    public enum Kind: Equatable, Sendable {
        case document, spreadsheet, presentation, pdf, archive, image, audio, video, text, other
    }

    public var kind: Kind { Self.classify(filename: filename, mediaType: mediaType).kind }

    /// 给人看的类型名，比如“Excel 表格”“ZIP 压缩包”，不直接显示 MIME 类型。
    public var typeDescription: String { Self.classify(filename: filename, mediaType: mediaType).name }

    private static let byExtension: [String: (Kind, String)] = [
        "xlsx": (.spreadsheet, "Excel 表格"), "xls": (.spreadsheet, "Excel 表格"), "xlsm": (.spreadsheet, "Excel 表格"),
        "numbers": (.spreadsheet, "Numbers 表格"), "csv": (.spreadsheet, "CSV 表格"),
        "docx": (.document, "Word 文档"), "doc": (.document, "Word 文档"), "pages": (.document, "Pages 文稿"),
        "rtf": (.document, "RTF 文档"),
        "pptx": (.presentation, "PowerPoint 演示文稿"), "ppt": (.presentation, "PowerPoint 演示文稿"),
        "key": (.presentation, "Keynote 演示文稿"),
        "pdf": (.pdf, "PDF 文档"),
        "zip": (.archive, "ZIP 压缩包"), "rar": (.archive, "RAR 压缩包"), "7z": (.archive, "7Z 压缩包"),
        "tar.gz": (.archive, "TAR.GZ 压缩包"), "tgz": (.archive, "TGZ 压缩包"), "gz": (.archive, "GZIP 压缩包"),
        "tar": (.archive, "TAR 归档"),
        "jpg": (.image, "JPEG 图片"), "jpeg": (.image, "JPEG 图片"), "png": (.image, "PNG 图片"),
        "gif": (.image, "GIF 图片"), "heic": (.image, "HEIC 图片"), "webp": (.image, "WebP 图片"),
        "mp3": (.audio, "MP3 音频"), "m4a": (.audio, "M4A 音频"), "wav": (.audio, "WAV 音频"),
        "mp4": (.video, "MP4 视频"), "mov": (.video, "MOV 视频"),
        "txt": (.text, "文本文件"), "md": (.text, "Markdown 文本"), "log": (.text, "日志文件"),
    ]

    private static let byMediaType: [String: (Kind, String)] = [
        "application/pdf": (.pdf, "PDF 文档"),
        "application/zip": (.archive, "ZIP 压缩包"), "application/gzip": (.archive, "GZIP 压缩包"),
        "application/x-gzip": (.archive, "GZIP 压缩包"),
        "application/msword": (.document, "Word 文档"),
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": (.document, "Word 文档"),
        "application/vnd.ms-excel": (.spreadsheet, "Excel 表格"),
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": (.spreadsheet, "Excel 表格"),
        "application/vnd.ms-powerpoint": (.presentation, "PowerPoint 演示文稿"),
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": (.presentation, "PowerPoint 演示文稿"),
        "text/csv": (.spreadsheet, "CSV 表格"),
        "text/plain": (.text, "文本文件"),
        "image/jpeg": (.image, "JPEG 图片"), "image/png": (.image, "PNG 图片"), "image/gif": (.image, "GIF 图片"),
    ]

    private static func classify(filename: String, mediaType: String) -> (kind: Kind, name: String) {
        let name = filename.lowercased()
        if name.hasSuffix(".tar.gz"), let known = byExtension["tar.gz"] { return known }
        let ext = (name as NSString).pathExtension
        // 扩展名只认短的字母数字，避免把“v1.0 说明”之类的名字当成类型
        let usable = !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if usable, let known = byExtension[ext] { return known }
        let type = mediaType.lowercased()
        if let known = byMediaType[type] { return known }
        if usable { return (.other, ext.uppercased() + " 文件") }
        let major = type.split(separator: "/").first.map(String.init) ?? ""
        switch major {
        case "image": return (.image, "图片")
        case "audio": return (.audio, "音频")
        case "video": return (.video, "视频")
        case "text": return (.text, "文本文件")
        default: return (.other, "文件")
        }
    }
}

/// 邮件头部的地址列表：默认一行，人多时只列前几个名字，加“等 N 人”。
public enum MailAddressList {
    public static let collapsedNames = 2

    public static func collapsed(_ values: [MailAddress]) -> String {
        guard !values.isEmpty else { return "未知" }
        if values.count == 1 { return full(values) }
        let names = values.prefix(collapsedNames).map(displayName).joined(separator: "、")
        return values.count > collapsedNames ? "\(names) 等 \(values.count) 人" : names
    }

    public static func full(_ values: [MailAddress]) -> String {
        guard !values.isEmpty else { return "未知" }
        return values.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: "、")
    }

    /// 折叠后丢了地址或人名时才需要展开
    public static func isExpandable(_ values: [MailAddress]) -> Bool { collapsed(values) != full(values) }

    public static func displayName(_ value: MailAddress) -> String { value.name.isEmpty ? value.address : value.name }
}
