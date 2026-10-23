import Foundation

/// Converts between plain text and the small HTML subset Notes stores.
///
/// User text is always HTML-escaped, so a note containing `<script>` is stored as visible text, never markup.
enum NoteHTML {
    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count + 16)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "\t": output += "&nbsp;&nbsp;&nbsp;&nbsp;"
            default: output.append(character)
            }
        }
        // Runs of spaces would collapse in HTML; keep them visible.
        return output.replacingOccurrences(of: "  ", with: " &nbsp;")
    }

    /// One `<div>` per line (blank lines become `<div><br></div>`), the shape Notes itself writes.
    static func paragraphs(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? "<div><br></div>" : "<div>\(escape(String(line)))</div>"
        }.joined()
    }

    /// The body of a brand-new note. The first line is the note's title in Notes, so the title becomes a heading.
    static func newNote(title: String?, content: String?) -> String {
        var html = ""
        if let title, !title.isEmpty { html += "<div><h1>\(escape(title))</h1></div>" }
        if let content, !content.isEmpty { html += paragraphs(content) }
        return html
    }

    /// Collapses whitespace so plain-text comparisons ignore formatting differences.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
