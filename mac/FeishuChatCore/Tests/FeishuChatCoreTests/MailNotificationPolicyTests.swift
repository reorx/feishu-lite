import Foundation
import Testing
@testable import FeishuChatCore

struct MailNotificationPolicyTests {
    private func batch() throws -> MailNotification {
        try JSONDecoder().decode(MailNotification.self,from:Data(#"{"id":"batch","account_id":"account","folder_id":"INBOX","uidvalidity":77,"mode":"individual","items":[{"id":"opaque","key":{"account_id":"account","folder_id":"INBOX","uidvalidity":77,"uid":1},"subject":"","sender":[],"to":[],"cc":[],"date":"","message_id":"","received_at":0,"size":0,"flags":[],"unread":true,"attachments":[],"body_part":null,"error":null}]}"#.utf8))
    }
    @Test func identityChecksRejectCrossAccountFolderAndValidity() throws {
        let batch = try batch()
        #expect(MailNotificationPolicy.eligible(batch,accountID:"account",uidvalidity:77))
        #expect(!MailNotificationPolicy.eligible(batch,accountID:"other",uidvalidity:77))
        #expect(!MailNotificationPolicy.eligible(batch,accountID:"account",uidvalidity:78))
        var wrong = batch; wrong.items[0].key.accountID = "other"
        #expect(!MailNotificationPolicy.eligible(wrong,accountID:"account",uidvalidity:77))
        wrong = batch; wrong.folderID = "Archive"
        #expect(!MailNotificationPolicy.eligible(wrong,accountID:"account",uidvalidity:77))
    }
    @Test(arguments:[AppModule.messages,.email])
    func suppressionUsesActualViewingContext(module: AppModule) throws {
        let row = try batch().items[0]
        let route = MailNotificationPolicy.route(for:row)
        for active in [true,false] {
            for visible in [true,false] {
                let context = ViewingContext(activeModule:module,isAppActive:active,isWindowVisible:visible,selectedChatID:nil,selectedMail:route)
                #expect(MailNotificationPolicy.shouldSuppress(row,context:context) == (module == .email && active && visible))
            }
        }
    }
}
