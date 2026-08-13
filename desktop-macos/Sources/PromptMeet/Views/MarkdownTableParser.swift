import Foundation

enum MarkdownTableAlignment: Equatable, Sendable {
    case left
    case center
    case right
}

struct MarkdownTableColumn: Equatable, Sendable {
    let header: String
    let cells: [String]
    let alignment: MarkdownTableAlignment
}

/// GFM-style table parsing for the block parser: header row, alignment
/// separator row, then data rows until a blank line.
enum MarkdownTableParser {
    static func consumeTable(_ lines: [String], index: inout Int) -> MarkdownBlock {
        let headerCells = splitRow(lines[index])
        var rawLines = [lines[index]]
        index += 1
        let alignments = separatorAlignments(lines[index]) ?? []
        rawLines.append(lines[index])
        index += 1

        var rows: [[String]] = []
        while index < lines.count,
            !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
            !MarkdownDocument.startsBlock(lines[index]),
            !MarkdownTableParser.isTableStart(lines, at: index) {
            rows.append(splitRow(lines[index]))
            rawLines.append(lines[index])
            index += 1
        }
        let columnCount = max(
            alignments.count,
            headerCells.count,
            rows.map(\.count).max() ?? 0
        )
        let columns: [MarkdownTableColumn] = (0..<columnCount).map { columnIndex in
            MarkdownTableColumn(
                header: columnIndex < headerCells.count ? headerCells[columnIndex] : "",
                cells: rows.map { row in
                    columnIndex < row.count ? row[columnIndex] : ""
                },
                alignment: columnIndex < alignments.count ? alignments[columnIndex] : .left
            )
        }
        return MarkdownBlock(kind: .table(columns: columns), lines: rawLines)
    }

    /// Splits a table row on unescaped pipes and trims cells.
    static func splitRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        for (offset, char) in line.enumerated() {
            if char == "|" {
                let escaped = isEscaped(line, at: offset)
                if escaped {
                    current.append(char)
                } else {
                    cells.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A GFM-style alignment separator row like `| :--- | ---: | :---: |`.
    static func separatorAlignments(_ line: String) -> [MarkdownTableAlignment]? {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let hasLeft = cell.hasPrefix(":")
            let hasRight = cell.hasSuffix(":")
            let core = cell
                .dropFirst(hasLeft ? 1 : 0)
                .dropLast(hasRight ? 1 : 0)
            guard core.count >= 1, core.allSatisfy({ $0 == "-" }) else { return nil }
            if hasLeft && hasRight {
                alignments.append(.center)
            } else if hasRight {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }

    static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard lines[index].contains("|"), index + 1 < lines.count else { return false }
        return separatorAlignments(lines[index + 1]) != nil
    }

    private static func isEscaped(_ line: String, at offset: Int) -> Bool {
        var slashCount = 0
        var cursor = line.index(line.startIndex, offsetBy: offset)
        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return !slashCount.isMultiple(of: 2)
    }
}
