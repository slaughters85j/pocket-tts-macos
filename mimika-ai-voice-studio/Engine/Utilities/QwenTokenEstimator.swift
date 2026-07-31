//
//  QwenTokenEstimator.swift
//  mimika-ai-voice-studio
//
//  Reference tokenizer for Ensemble context fill %. Loads the vendored Qwen3
//  HuggingFace `tokenizer.json` and counts tokens with ByteLevel BPE.
//  Exact for Qwen-family models; ballpark for others — used with a 90% toast,
//  not a hard cut-off.
//

import Foundation

// MARK: - QwenTokenEstimator

/// Lazy, thread-safe token counter backed by bundled Qwen3 BPE assets.
final class QwenTokenEstimator: @unchecked Sendable {

    static let shared = QwenTokenEstimator()

    /// From bundled `tokenizer_config.json` (`model_max_length`), if present.
    private(set) var modelMaxLength: Int = 262_144

    private var vocab: [String: Int] = [:]
    private var mergeRanks: [String: Int] = [:]  // "a b" → rank
    private var byteEncoder: [UInt8: Character] = [:]
    private var didLoad = false
    private var loadFailed = false
    private let lock = NSLock()

    private init() {
        buildByteEncoder()
    }

    /// Token count for `text`. Falls back to a Qwen-ish char heuristic if the
    /// bundled tokenizer cannot load.
    func countTokens(_ text: String) -> Int {
        ensureLoaded()
        if loadFailed || vocab.isEmpty {
            return max(text.isEmpty ? 0 : 1, (text.utf8.count + 2) / 3)
        }
        let n = encodeCount(text)
        return text.isEmpty ? 0 : max(n, 1)
    }

    // MARK: - Load

    private func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLoad else { return }
        didLoad = true
        do {
            try loadBundledTokenizer()
        } catch {
            #if DEBUG
            print("[QwenTokenEstimator] load failed: \(error)")
            #endif
            loadFailed = true
        }
    }

    private func loadBundledTokenizer() throws {
        let jsonURL =
            Bundle.main.url(
                forResource: "tokenizer",
                withExtension: "json",
                subdirectory: "tokenizers/qwen3"
            )
            ?? Bundle.main.url(forResource: "tokenizer", withExtension: "json")
        guard let jsonURL else { throw EstimatorError.missingBundleAsset }

        let jsonData = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        guard
            let model = root?["model"] as? [String: Any],
            let vocabObj = model["vocab"] as? [String: Any],
            let merges = model["merges"] as? [Any]
        else {
            throw EstimatorError.invalidTokenizerJSON
        }

        var v: [String: Int] = [:]
        v.reserveCapacity(vocabObj.count)
        for (k, raw) in vocabObj {
            if let i = raw as? Int {
                v[k] = i
            } else if let n = raw as? NSNumber {
                v[k] = n.intValue
            }
        }
        vocab = v

        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (i, item) in merges.enumerated() {
            if let pair = item as? [String], pair.count == 2 {
                ranks["\(pair[0]) \(pair[1])"] = i
            } else if let s = item as? String {
                ranks[s] = i
            }
        }
        mergeRanks = ranks

        if let cfgURL = Bundle.main.url(
            forResource: "tokenizer_config",
            withExtension: "json",
            subdirectory: "tokenizers/qwen3"
        ),
           let cfgData = try? Data(contentsOf: cfgURL),
           let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] {
            if let maxLen = cfg["model_max_length"] as? Int {
                modelMaxLength = maxLen
            } else if let maxLen = cfg["model_max_length"] as? Double {
                modelMaxLength = Int(maxLen)
            }
        }
        #if DEBUG
        print("[QwenTokenEstimator] loaded vocab=\(vocab.count) merges=\(mergeRanks.count) maxLen=\(modelMaxLength)")
        #endif
    }

    // MARK: - Encode (count only)

    private func encodeCount(_ text: String) -> Int {
        let normalized = text.precomposedStringWithCanonicalMapping
        var total = 0
        for piece in pretokens(normalized) {
            let byteLevel = String(piece.utf8.map { byteEncoder[$0]! })
            total += bpe(byteLevel).count
        }
        return total
    }

    /// Approximate the HF Split regex with a practical Unicode-aware splitter.
    private func pretokens(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        for ch in text {
            if ch.isWhitespace {
                flush()
                if let last = parts.last, last.allSatisfy(\.isWhitespace) {
                    parts[parts.count - 1] = last + String(ch)
                } else {
                    parts.append(String(ch))
                }
            } else if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if !current.isEmpty {
                    flush()
                }
                current.append(ch)
            }
        }
        flush()
        return parts.filter { !$0.isEmpty }
    }

    private func bpe(_ token: String) -> [String] {
        if token.isEmpty { return [] }
        var word = token.map(String.init)
        if word.count == 1 { return word }

        while true {
            guard word.count >= 2 else { break }
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(word.count - 1) {
                let key = word[i] + " " + word[i + 1]
                if let r = mergeRanks[key], r < bestRank {
                    bestRank = r
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }
            let merged = word[bestIndex] + word[bestIndex + 1]
            var next: [String] = []
            next.reserveCapacity(word.count - 1)
            var i = 0
            while i < word.count {
                if i == bestIndex {
                    next.append(merged)
                    i += 2
                } else {
                    next.append(word[i])
                    i += 1
                }
            }
            word = next
        }
        return word.filter { vocab[$0] != nil }
    }

    private func buildByteEncoder() {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            map[UInt8(b)] = Character(UnicodeScalar(c)!)
        }
        byteEncoder = map
    }

    enum EstimatorError: Error {
        case missingBundleAsset
        case invalidTokenizerJSON
    }
}
