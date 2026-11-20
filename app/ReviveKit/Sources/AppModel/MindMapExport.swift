import Foundation
import Library

/// A summary's outline (G1 大纲) as OPML, the outline format XMind, 幕布, MindNode and most
/// outliners import (features.md J1 思维导图). The recording title is the root, each topic a
/// branch, each point a leaf. Made on the phone; nothing is sent anywhere.
public enum MindMapExport {
    public static func opml(title: String, outline: [OutlineItem]) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head><title>\(escape(title))</title></head>",
            "  <body>",
            "    <outline text=\"\(escape(title))\">",
        ]
        for item in outline {
            if item.points.isEmpty {
                lines.append("      <outline text=\"\(escape(item.title))\"/>")
            } else {
                lines.append("      <outline text=\"\(escape(item.title))\">")
                lines += item.points.map { "        <outline text=\"\(escape($0))\"/>" }
                lines.append("      </outline>")
            }
        }
        lines += ["    </outline>", "  </body>", "</opml>"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// XML attribute text: markup characters escaped, control characters other than tab and
    /// newline dropped (they are not allowed in XML 1.0).
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n": out += "&#10;"
            case "\t": out += "&#9;"
            default:
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
