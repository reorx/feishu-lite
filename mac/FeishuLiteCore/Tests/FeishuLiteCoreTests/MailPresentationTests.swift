import Foundation
import Testing
@testable import FeishuLiteCore

struct MailPresentationTests {
    private func folder(_ id: String, _ name: String, readable: Bool = false, selectable: Bool = true,
                        delimiter: String? = "/") -> MailFolder {
        MailFolder(id:id,name:name,delimiter:delimiter,flags:[],selectable:selectable,supported:readable)
    }

    @Test func folderMenuShowsNamesIndentedUnderTheirParentsWithInboxFirst() {
        let folders = [
            folder("Sent Messages","已发送"),
            folder("归档","归档",selectable:false),
            folder("Junk","垃圾邮件"),
            folder("归档/2025 年项目资料","2025 年项目资料"),
            folder("INBOX","收件箱",readable:true),
            folder("归档/2025 年项目资料/合同","合同"),
        ]
        let entries = MailFolderMenu.entries(folders)
        #expect(entries.map(\.title) == ["收件箱","已发送","归档","2025 年项目资料","合同","垃圾邮件"])
        #expect(entries.map(\.depth) == [0,0,0,1,2,0])
        #expect(entries.map(\.isReadable) == [true,false,false,false,false,false])
    }

    @Test func folderMenuKeepsOrphansAtTheTopLevelAndFallsBackToTheLastPathComponent() {
        let folders = [
            folder("INBOX","收件箱",readable:true),
            folder("项目/周报","",delimiter:"/"),
            folder("Flat.Child","Flat.Child",delimiter:nil),
        ]
        let entries = MailFolderMenu.entries(folders)
        // 父文件夹不在列表里时不缩进，名字为空时取路径最后一段
        #expect(entries.map(\.title) == ["收件箱","周报","Flat.Child"])
        #expect(entries.map(\.depth) == [0,0,0])
    }

    @Test func folderReadabilityMatchesTheInboxOnlyReader() {
        let entries = MailFolderMenu.entries([
            folder("INBOX","收件箱",readable:false),
            folder("Other","其他",readable:true),
        ])
        #expect(entries.map(\.isReadable) == [false,false])
    }

    @Test func folderButtonTitleFollowsTheCurrentFolder() {
        let folders = [folder("INBOX","Inbox",readable:true), folder("Sent","已发送")]
        #expect(MailFolderMenu.title(for:"INBOX",in:folders) == "Inbox")
        #expect(MailFolderMenu.title(for:"Sent",in:folders) == "已发送")
        #expect(MailFolderMenu.title(for:"INBOX",in:[]) == "收件箱")
    }

    private func attachment(_ name: String, _ type: String) -> MailAttachment {
        MailAttachment(section:"2",filename:name,mediaType:type,encodedSize:nil,sizeIsApproximate:false,contentID:nil)
    }

    @Test func attachmentTypeIsAFriendlyNameNotTheRawMIMEType() {
        let xlsx = attachment("审查清单.xlsx","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        #expect(xlsx.typeDescription == "Excel 表格")
        #expect(xlsx.kind == .spreadsheet)
        #expect(attachment("说明.pdf","application/pdf").typeDescription == "PDF 文档")
        #expect(attachment("包.zip","application/zip").typeDescription == "ZIP 压缩包")
        #expect(attachment("archive.tar.gz","application/gzip").typeDescription == "TAR.GZ 压缩包")
        #expect(attachment("photo.JPG","image/jpeg").typeDescription == "JPEG 图片")
        #expect(attachment("extra.docx","application/msword").typeDescription == "Word 文档")
        #expect(attachment("slides.pptx","application/octet-stream").typeDescription == "PowerPoint 演示文稿")
        #expect(attachment("notes.txt","text/plain").typeDescription == "文本文件")
        #expect(attachment("data.parquet","application/octet-stream").typeDescription == "PARQUET 文件")
    }

    @Test func attachmentWithoutAUsableExtensionFallsBackToTheMIMEType() {
        #expect(attachment("","application/octet-stream").typeDescription == "文件")
        #expect(attachment("","image/png").typeDescription == "PNG 图片")
        #expect(attachment("scan","application/pdf").typeDescription == "PDF 文档")
        #expect(attachment("report","application/vnd.openxmlformats-officedocument.wordprocessingml.document").typeDescription == "Word 文档")
        #expect(attachment("clip","video/mp4").kind == .video)
        #expect(attachment("weird.name with space","text/csv").typeDescription == "CSV 表格")
        #expect(attachment("","").typeDescription == "文件")
    }

    private func address(_ name: String, _ value: String) -> MailAddress { MailAddress(name:name,address:value) }

    @Test func recipientsCollapseToOneLineWithATotalCount() {
        let one = [address("审查用户","u1@example.invalid")]
        #expect(MailAddressList.collapsed(one) == "审查用户 <u1@example.invalid>")
        #expect(!MailAddressList.isExpandable(one))
        let two = [address("张三","a@example.invalid"), address("","b@example.invalid")]
        #expect(MailAddressList.collapsed(two) == "张三、b@example.invalid")
        #expect(MailAddressList.isExpandable(two))
        let many = (1...9).map { address("收件人\($0)","r\($0)@example.invalid") }
        #expect(MailAddressList.collapsed(many) == "收件人1、收件人2 等 9 人")
        #expect(MailAddressList.full(many).hasPrefix("收件人1 <r1@example.invalid>、收件人2 <r2@example.invalid>"))
        #expect(MailAddressList.isExpandable(many))
    }

    @Test func missingAddressesReadAsUnknown() {
        #expect(MailAddressList.collapsed([]) == "未知")
        #expect(MailAddressList.full([]) == "未知")
        #expect(!MailAddressList.isExpandable([]))
        #expect(MailAddressList.collapsed([address("","only@example.invalid")]) == "only@example.invalid")
    }
}
