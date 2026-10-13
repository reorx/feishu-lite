import Foundation

public enum MailNotificationPolicy {
    public static func route(for item: MailSummary) -> NotificationRoute {
        .email(accountID:item.key.accountID,folderID:item.key.folderID,messageID:item.id)
    }
    public static func eligible(_ batch: MailNotification, accountID: String, uidvalidity: Int) -> Bool {
        batch.accountID == accountID && batch.folderID == "INBOX" && batch.uidvalidity == uidvalidity
            && !batch.id.isEmpty && batch.items.allSatisfy {
                !$0.id.isEmpty && $0.key.accountID == accountID && $0.key.folderID == "INBOX" && $0.key.uidvalidity == uidvalidity
            }
    }
    public static func shouldSuppress(_ item: MailSummary, context: ViewingContext) -> Bool {
        !item.unread || context.viewingMail == route(for:item)
    }
}
