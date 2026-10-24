import Foundation

enum MailScripts {
    private static func make(_ name: String, _ body: String) -> AppleScriptSource {
        AppleScriptSource(name: "mail." + name, text: ScriptPrelude.handlers + "\n" + helpers + "\n" + body)
    }
    private static let helpers = #"""
        on selectedBox(boxName)
        tell application "Mail"
        if boxName is "sent" then return sent mailbox
        if boxName is "drafts" then return drafts mailbox
        return inbox
        end tell
        end selectedBox
        on lookupMessage(mid, boxName)
        set boxRef to my selectedBox(boxName)
        tell application "Mail"
        set found to messages of boxRef whose id is (mid as integer)
        if count of found is not 1 then error "NOT_FOUND|message" number 9001
        return item 1 of found
        end tell
        end lookupMessage
        on draftFields(d)
        tell application "Mail"
        set tos to address of to recipients of d
        set ccs to address of cc recipients of d
        set bccs to address of bcc recipients of d
        set AppleScript's text item delimiters to ", "
        set toText to tos as text
        set ccText to ccs as text
        set bccText to bccs as text
        set AppleScript's text item delimiters to ""
        set fields to {(id of d) as text, my safeText(subject of d), my safeText(content of d), my oneLine(toText), my oneLine(ccText), my oneLine(bccText), my oneLine(sender of d)}
        repeat with a in attachments of content of d
        set end of fields to my safeText(POSIX path of (file name of a as alias))
        end repeat
        return my joinFields(fields)
        end tell
        end draftFields
        """#
    static let search = make(
        "search",
        #"""
        on run argv
        set queryText to item 1 of argv
        set senderText to item 2 of argv
        set boxRef to my selectedBox(item 3 of argv)
        set rows to {}
        tell application "Mail"
        set candidates to messages of boxRef
        set n to count of candidates
        if n > 500 then set n to 500
        repeat with i from 1 to n
        set m to item i of candidates
        set subj to subject of m
        set who to sender of m
        if (queryText is "" or subj contains queryText) and (senderText is "" or who contains senderText) then
        set attachmentNames to {}
        repeat with a in mail attachments of m
        set end of attachmentNames to my oneLine(name of a)
        end repeat
        set AppleScript's text item delimiters to ", "
        set attachmentText to attachmentNames as text
        set AppleScript's text item delimiters to ""
        set end of rows to my joinFields({(id of m) as text, my oneLine(subj), my oneLine(who), ((date received of m) as «class isot») as string, (read status of m) as text, my oneLine(attachmentText)})
        end if
        end repeat
        end tell
        return my joinRecords(rows)
        end run
        """#)
    static let read = make(
        "read",
        #"""
        on run argv
        set m to my lookupMessage(item 1 of argv, item 2 of argv)
        tell application "Mail"
        set bodyText to content of m as text
        set fullLength to count of characters of bodyText
        set maxChars to (item 3 of argv) as integer
        if fullLength > maxChars then set bodyText to text 1 thru maxChars of bodyText
        return my joinFields({(id of m) as text, my oneLine(subject of m), my oneLine(sender of m), my safeText(bodyText), fullLength as text, my oneLine(message id of m)})
        end tell
        end run
        """#)
    static let draft = make(
        "draft",
        #"""
        on run argv
        tell application "Mail"
        set d to make new outgoing message with properties {subject:(item 1 of argv), content:(item 2 of argv), visible:false}
        tell d
        repeat with i from 3 to count of argv
        make new to recipient at end of to recipients with properties {address:(item i of argv)}
        end repeat
        end tell
        save d
        return my draftFields(d)
        end tell
        end run
        """#)
    static let reply = make(
        "reply",
        #"""
        on run argv
        set m to my lookupMessage(item 1 of argv, item 2 of argv)
        tell application "Mail"
        set d to reply m opening window false reply to all false
        set content of d to (item 3 of argv) & return & return & (content of d as text)
        save d
        return my draftFields(d)
        end tell
        end run
        """#)
    static let forward = make(
        "forward",
        #"""
        on run argv
        set m to my lookupMessage(item 1 of argv, item 2 of argv)
        tell application "Mail"
        set d to forward m opening window false
        set content of d to (item 3 of argv) & return & return & (content of d as text)
        tell d
        repeat with i from 4 to count of argv
        make new to recipient at end of to recipients with properties {address:(item i of argv)}
        end repeat
        end tell
        save d
        return my draftFields(d)
        end tell
        end run
        """#)
    static let readDraft = make(
        "read_draft",
        #"""
        on run argv
        tell application "Mail"
        set found to outgoing messages whose id is ((item 1 of argv) as integer)
        if count of found is not 1 then error "NOT_FOUND|draft" number 9001
        return my draftFields(item 1 of found)
        end tell
        end run
        """#)
    static let attach = make(
        "attach",
        #"""
        on run argv
        tell application "Mail"
        set found to outgoing messages whose id is ((item 1 of argv) as integer)
        if count of found is not 1 then error "NOT_FOUND|draft" number 9001
        set d to item 1 of found
        tell content of d
        make new attachment with properties {file name:(POSIX file (item 2 of argv))} at after last paragraph
        end tell
        save d
        return my draftFields(d)
        end tell
        end run
        """#)
    static let send = make(
        "send",
        #"""
        on run argv
        tell application "Mail"
        set found to outgoing messages whose id is ((item 1 of argv) as integer)
        if count of found is not 1 then error "NOT_FOUND|draft" number 9001
        set d to item 1 of found
        if my draftFields(d) is not item 2 of argv then error "CHANGED|draft" number 9003
        set accepted to send d
        if accepted is false then error "FAILED|send" number 9005
        return "accepted"
        end tell
        end run
        """#)
    static let all = [search, read, draft, reply, forward, readDraft, attach, send]
}
