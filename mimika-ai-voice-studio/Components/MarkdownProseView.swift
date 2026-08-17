//
//  MarkdownProseView.swift
//  mimika-ai-voice-studio
//
//  Shared Markdown rendering for both transcripts: inline styling via
//  AttributedString, fenced code in its own panel, and GFM pipe tables as a real
//  grid (Foundation's Markdown parser has no table support at all, so a table
//  would otherwise render as literal "| Shift | Role |" text).
//

import SwiftUI

// MARK: - MarkdownProseView

struct MarkdownProseView: View {
    let source: String
    var textColor: Color = .white
    /// Ensemble turns are one paragraph; Solo replies can be long documents.
    var codeBackground: Color = Color(red: 0.12, green: 0.13, blue: 0.16)

    var body: some View {
        if let plain = Self.plainTextFastPath(source) {
            // Ordinary spoken dialogue — the overwhelmingly common case in
            // Ensemble, which re-renders on every streamed token. Skip the
            // parser entirely rather than segmenting a string with no markup.
            Text(plain)
                .font(Theme.fontSM)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: Theme.space3) {
                ForEach(Array(ChatMarkdownParser.parse(source).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case let .prose(markdown):
                        Text(Self.attributed(markdown))
                            .font(Theme.fontSM)
                            .foregroundStyle(textColor)
                            .tint(textColor.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case let .code(_, content):
                        Text(content.isEmpty ? " " : content)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(textColor.opacity(0.82))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, Theme.space2)
                            .background(codeBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    case let .table(header, rows):
                        MarkdownTable(header: header, rows: rows, textColor: textColor)
                    }
                }
            }
        }
    }

    /// Returns the string unchanged when it carries no block-level markup worth
    /// parsing, otherwise `nil`. Deliberately conservative — a false negative
    /// only costs one parse, a false positive would drop formatting.
    private static func plainTextFastPath(_ s: String) -> String? {
        s.contains(where: { $0 == "|" || $0 == "`" || $0 == "*" || $0 == "_" || $0 == "#" || $0 == "[" })
            ? nil
            : s
    }

    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}

// MARK: - Table

/// GFM pipe table drawn as a grid. Horizontally scrollable so a wide table
/// cannot stretch the containing bubble or transcript row.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    var textColor: Color = .white

    private var columnCount: Int { max(header.count, 1) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Grid sizes every column in one pass — no per-row renegotiation.
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        cellText(cell, bold: true)
                    }
                }
                .background(textColor.opacity(0.14))

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                        .overlay(textColor.opacity(0.18))
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            cellText(column < row.count ? row[column] : "", bold: false)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : textColor.opacity(0.05))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(textColor.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    /// Cells carry inline Markdown — generated tables lean on `**bold**`.
    private func cellText(_ raw: String, bold: Bool) -> some View {
        Text(MarkdownProseView.attributed(raw))
            .font(Theme.fontXS)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, 5)
            .frame(maxWidth: 260, alignment: .leading)
    }
}
