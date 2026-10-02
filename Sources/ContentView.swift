import SwiftUI
import CryptoKit
import UIKit

// MARK: - 历史记录模型
struct Record: Identifiable, Codable {
    let id: String
    var type: String
    var mode: String
    var input: String
    var output: String
    var time: String
}

// MARK: - 核心算法
private func md5(_ s: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// 解析 \uXXXX 序列（宽松：仅替换匹配部分，其余原样保留）
private func unicodeDecode(_ input: String) throws -> String {
    let ns = input as NSString
    let regex = try NSRegularExpression(pattern: #"\\u([0-9A-Fa-f]{4})"#)
    let results = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
    guard !results.isEmpty else {
        throw NSError(domain: "codec", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "未找到合法的 \\uXXXX 序列"])
    }
    var out = input
    for r in results.reversed() {
        let hex = ns.substring(with: r.range(at: 1))
        if let v = UInt32(hex, radix: 16), let sc = UnicodeScalar(v) {
            out = (out as NSString).replacingCharacters(in: r.range, with: String(sc))
        }
    }
    return out
}

/// 与 JS encodeURIComponent 一致的字符白名单
private func urlEncodeSet() -> CharacterSet {
    var c = CharacterSet.alphanumerics
    c.insert(charactersIn: "-_.!~*'()")
    return c
}

private func process(type: String, mode: String, input: String) throws -> String {
    guard !input.isEmpty else { return "" }

    if type == "url" {
        if mode == "encode" {
            return input.addingPercentEncoding(withAllowedCharacters: urlEncodeSet()) ?? input
        } else {
            guard let r = input.removingPercentEncoding else {
                throw NSError(domain: "codec", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "包含无效的 URL 编码序列"])
            }
            return r
        }
    } else if type == "base64" {
        if mode == "encode" {
            return Data(input.utf8).base64EncodedString()
        } else {
            let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) else {
                throw NSError(domain: "codec", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "不是合法的 Base64 字符串"])
            }
            guard let s = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "codec", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "解码结果不是有效的 UTF-8 文本"])
            }
            return s
        }
    } else if type == "unicode" {
        if mode == "encode" {
            return input.unicodeScalars.map { String(format: "\\u%04X", $0.value) }.joined()
        } else {
            return try unicodeDecode(input)
        }
    } else if type == "md5" {
        return md5(input)
    }
    return input
}

// MARK: - 历史存储
private func loadHistory() -> [Record] {
    guard let d = UserDefaults.standard.data(forKey: "codec_history") else { return [] }
    return (try? JSONDecoder().decode([Record].self, from: d)) ?? []
}
private func saveHistory(_ h: [Record]) {
    if let d = try? JSONEncoder().encode(Array(h.prefix(200))) {
        UserDefaults.standard.set(d, forKey: "codec_history")
    }
}

// MARK: - 主界面
struct ContentView: View {
    @State private var type = "url"
    @State private var mode = "encode"
    @State private var input = ""
    @State private var errorMsg = ""
    @State private var showHistory = false
    @State private var history: [Record] = loadHistory()
    @State private var toast = ""
    @AppStorage("codec_dark") private var darkMode = false

    private let types: [(String, String)] = [("url", "URL"), ("base64", "Base64"),
                                             ("unicode", "Unicode"), ("md5", "MD5")]

    private var output: String {
        do {
            errorMsg = ""
            return try process(type: type, mode: mode, input: input)
        } catch {
            errorMsg = (error as NSError).localizedDescription
            return ""
        }
    }

    private var placeholder: String {
        if type == "md5" { return "输入任意文本（计算 32 位 MD5）" }
        if type == "url" { return "输入文本（将进行 URL 编码/解码）" }
        if type == "base64" { return "输入文本或 Base64 字符串" }
        return "输入文本或 \\uXXXX 序列"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("功能", selection: $type) {
                        ForEach(types, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: type) { _ in if type == "md5" { mode = "encode" } }

                    if type != "md5" {
                        Picker("模式", selection: $mode) {
                            Text("编码").tag("encode")
                            Text("解码").tag("decode")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }

                    Text(placeholder)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $input)
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.body)

                    HStack { Spacer(); Image(systemName: "arrow.down").foregroundColor(.secondary); Spacer() }

                    Text(type == "md5" ? "MD5 摘要" : (mode == "encode" ? "编码结果" : "解码结果"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView {
                        Text(output.isEmpty ? (errorMsg.isEmpty ? "结果将实时显示…" : errorMsg) : output)
                            .foregroundColor(errorMsg.isEmpty ? .primary : .red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                    HStack(spacing: 10) {
                        Button(action: copyResult) {
                            Label("复制结果", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BorderedProminentButtonStyle())

                        Button(action: saveRecord) {
                            Label("存为历史", systemImage: "bookmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BorderedButtonStyle())
                    }
                }
                .padding()
            }
            .navigationTitle("编码解码工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { darkMode.toggle() }) {
                        Image(systemName: darkMode ? "sun.max.fill" : "moon.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showHistory = true }) {
                        Image(systemName: "clock")
                    }
                }
            }
            .preferredColorScheme(darkMode ? .dark : nil)
            .sheet(isPresented: $showHistory) {
                HistoryView(history: $history)
            }
            .overlay(
                Group {
                    if !toast.isEmpty {
                        Text(toast)
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(20)
                            .padding(.bottom, 24)
                    }
                },
                alignment: .bottom
            )
        }
    }

    private func copyResult() {
        guard !output.isEmpty else { showToast("没有可复制的内容"); return }
        UIPasteboard.general.string = output
        showToast("已复制到剪贴板")
    }

    private func saveRecord() {
        guard !input.isEmpty, !output.isEmpty else { showToast("请先输入并得到结果"); return }
        if history.contains(where: { $0.type == type && $0.mode == mode && $0.input == input }) {
            showToast("该记录已存在"); return
        }
        let r = Record(id: UUID().uuidString, type: type, mode: mode,
                       input: input, output: output,
                       time: DateFormatter.localizedString(from: Date(),
                                                          dateStyle: .short, timeStyle: .short))
        history.insert(r, at: 0)
        saveHistory(history)
        showToast("已保存到历史")
    }

    private func showToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toast == msg { toast = "" }
        }
    }
}

// MARK: - 历史界面
struct HistoryView: View {
    @Binding var history: [Record]
    @Environment(\.dismiss) private var dismiss

    private func typeName(_ t: String) -> String {
        ["url": "URL", "base64": "Base64", "unicode": "Unicode", "md5": "MD5"][t] ?? t
    }

    var body: some View {
        NavigationView {
            List {
                if history.isEmpty {
                    Text("暂无历史记录，处理结果后可点「存为历史」")
                        .foregroundColor(.secondary)
                }
                ForEach(history) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(typeName(r.type))
                                .font(.caption.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(8)
                            if r.type != "md5" {
                                Text(r.mode == "encode" ? "编码" : "解码")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(r.time).font(.caption2).foregroundColor(.secondary)
                        }
                        Text("输入：\(r.input)").font(.caption).lineLimit(2)
                        Text("输出：\(r.output)").font(.caption).lineLimit(2).foregroundColor(.secondary)
                        Button("复制输出") { UIPasteboard.general.string = r.output }
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            history.removeAll { $0.id == r.id }
                            saveHistory(history)
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
