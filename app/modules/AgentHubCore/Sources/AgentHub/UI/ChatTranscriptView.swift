//
//  ChatTranscriptView.swift
//  AgentHub
//
//  A chat layer over a session transcript: your messages on the right, the agent
//  on the left, tool steps as compact rows. Updates when the transcript file
//  changes (kqueue), not on a timer. The composer types into the real session.
//

import AppKit
import SwiftUI

// No `.textSelection(.enabled)` anywhere in the chat: its AppKit overlay resets the
// font on every update, which re-triggers layout and froze the app on open. Copy
// goes through CopyChip and the context menus instead.
struct ChatTranscriptView: View {
  let transcriptPath: String?
  let providerKind: SessionProviderKind
  let reader: any ChatTranscriptReading
  /// Sends a message into the session; nil makes the view read-only (subagents).
  var onSend: ((String) -> Bool)?
  /// Something only the terminal shows right now (an approval prompt).
  var terminalNotice: String? = nil
  var onShowTerminal: (() -> Void)? = nil
  /// The tool call waiting for approval, when known (Claude reports it).
  var pendingApproval: (tool: String, detail: String?)? = nil
  /// Approves in the terminal (selects the first option); returns false if it couldn't.
  var onApprove: (() -> Bool)? = nil

  @State private var items: [ChatTranscriptItem] = []
  @State private var draft = ""
  @State private var sendFailed = false
  @State private var changeCounter = 0
  /// How many of the newest groups are shown; older ones load on request. Opening
  /// a session scrolls to the bottom, which lays out every row above it.
  @State private var visibleGroupLimit = Self.pageSize

  static let pageSize = 60

  /// Width of the chat column: messages and composer share it.
  static let contentWidth: CGFloat = 820

  var body: some View {
    VStack(spacing: 0) {
      if let terminalNotice, let onShowTerminal {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(pendingApproval.map { "Approve \($0.tool)?" } ?? terminalNotice)
              .font(.secondaryDefault.weight(.semibold))
            if let detail = pendingApproval?.detail, !detail.isEmpty {
              Text(detail)
                .font(.jetBrainsMono(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
          }
          Spacer()
          if pendingApproval != nil, let onApprove {
            Button("Approve") { _ = onApprove() }
              .buttonStyle(.borderedProminent)
              .tint(.orange)
              .controlSize(.small)
              .help("Choose the first option in the terminal prompt (allow once)")
          }
          Button("Show terminal", action: onShowTerminal)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        Divider()
      }
      if transcriptPath == nil {
        ContentUnavailableView(
          "No transcript yet", systemImage: "bubble.left.and.bubble.right",
          description: Text("The chat appears once the session has written its first message."))
      } else {
        messages
      }
      if let onSend {
        Divider()
        // Same column as the messages, so the composer lines up with the chat.
        VStack(spacing: 0) {
          if !quickReplies.isEmpty {
            QuickReplyBar(replies: quickReplies) { reply in
              if onSend(reply) { sendFailed = false } else { sendFailed = true }
            }
          }
          ChatComposer(draft: $draft, sendFailed: sendFailed) {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if onSend(text) {
              draft = ""
              sendFailed = false
            } else {
              sendFailed = true
            }
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg - DesignTokens.Spacing.md)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
      }
    }
    .task(id: transcriptPath) {
      let file = transcriptPath.map { ($0 as NSString).lastPathComponent } ?? "none"
      AppLogger.chat.notice("Chat opened: \(file, privacy: .public)")
      MainThreadStallMonitor.breadcrumb("chat opened: \(file)")
      await reload()
    }
    .task(id: changeCounter) { await reload() }
    .background(TranscriptFileWatcher(path: transcriptPath) { changeCounter += 1 })
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        // VStack, not LazyVStack: a lazy stack with rows of varying height plus
        // scrolling to the bottom kept re-measuring and froze the app. At most
        // `pageSize` groups are built, so an eager stack stays cheap.
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
          let groups = groupedItems
          if groups.count > visibleGroupLimit {
            Button("Show earlier messages (\(groups.count - visibleGroupLimit))") {
              visibleGroupLimit += Self.pageSize
            }
            .buttonStyle(.borderless)
            .font(.secondaryDefault)
            .frame(maxWidth: .infinity)
          }
          ForEach(groups.suffix(visibleGroupLimit)) { group in
            ChatGroupView(group: group, providerKind: providerKind)
              .id(group.id)
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: items.count) { oldCount, newCount in
        // Follow new messages; the first load starts at the bottom via the anchor.
        guard oldCount > 0, newCount > oldCount else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
      }
    }
  }

  /// Consecutive tool steps collapse into one group so the chat stays readable.
  private var groupedItems: [ChatGroup] {
    var groups: [ChatGroup] = []
    for item in items {
      if case .tool = item.kind, case .tools(let tools)? = groups.last?.content {
        groups[groups.count - 1] = ChatGroup(id: groups[groups.count - 1].id, content: .tools(tools + [item]))
      } else if case .tool = item.kind {
        groups.append(ChatGroup(id: item.id, content: .tools([item])))
      } else {
        groups.append(ChatGroup(id: item.id, content: .message(item)))
      }
    }
    return groups
  }

  /// One-tap answers when the agent's last message asks something.
  private var quickReplies: [QuickReply] {
    guard case .assistant(let text)? = items.last?.kind else { return [] }
    return QuickReply.replies(for: text)
  }

  private func reload() async {
    guard let transcriptPath else { return }
    let started = Date()
    let latest = await reader.items(at: transcriptPath, provider: providerKind)
    guard latest != items else { return }
    let isFirstLoad = items.isEmpty
    items = latest
    let file = (transcriptPath as NSString).lastPathComponent
    if isFirstLoad {
      AppLogger.chat.notice(
        "Chat loaded \(latest.count) items for \(file, privacy: .public) in \(Date().timeIntervalSince(started) * 1000, format: .fixed(precision: 0))ms")
      MainThreadStallMonitor.breadcrumb("chat loaded \(latest.count) items: \(file)")
    }
  }
}

struct ChatGroup: Identifiable {
  enum Content {
    case message(ChatTranscriptItem)
    case tools([ChatTranscriptItem])
  }

  let id: String
  let content: Content
}

// MARK: - ChatGroupView

private struct ChatGroupView: View {
  let group: ChatGroup
  let providerKind: SessionProviderKind

  var body: some View {
    switch group.content {
    case .message(let item):
      switch item.kind {
      case .user(let text): UserBubble(text: text)
      case .assistant(let text): AssistantMessage(text: text, providerKind: providerKind)
      case .tool: EmptyView()
      }
    case .tools(let tools):
      ToolStepsView(tools: tools)
    }
  }
}

private struct UserBubble: View {
  let text: String
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack {
      Spacer(minLength: 80)
      Text(text)
        .font(.geist(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.brandPrimary(from: runtimeTheme).opacity(0.18))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.brandPrimary(from: runtimeTheme).opacity(0.3), lineWidth: 1)
        )
        .contextMenu {
          Button("Copy Message") { ChatClipboard.copy(text) }
        }
    }
    .accessibilityLabel("You: \(text)")
  }
}

private struct AssistantMessage: View {
  let text: String
  let providerKind: SessionProviderKind
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(Color.brandPrimary(for: providerKind))
        .frame(width: 22, height: 22)
        .overlay(
          Text(String(providerKind.rawValue.prefix(1)))
            .font(.geist(size: 11, weight: .bold))
            .foregroundStyle(.white)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        // Not MarkdownUI: its layout made opening a long session freeze the app.
        ChatMarkdownText(text: text)
          .frame(maxWidth: .infinity, alignment: .leading)
        let blocks = ChatCodeBlocks.extract(from: text)
        if !blocks.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
              CopyChip(label: block.preview, value: block.code, monospaced: true)
            }
          }
        }
      }
      VStack {
        CopyChip(label: nil, value: text, monospaced: false)
          .opacity(isHovered ? 1 : 0)
        Spacer()
      }
      .frame(width: 40)
    }
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Copy Message") { ChatClipboard.copy(text) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(providerKind.rawValue): \(text)")
  }
}

private struct ToolStepsView: View {
  let tools: [ChatTranscriptItem]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Image(systemName: "wrench.and.screwdriver")
            .font(.system(size: 10))
          Text(summary)
            .font(.secondarySmall)
            .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isExpanded {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(tools) { tool in
            if case .tool(let name, let detail) = tool.kind {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                  .font(.geist(size: 11, weight: .semibold))
                Text(detail)
                  .font(.jetBrainsMono(size: 11))
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
        .padding(.leading, 26)
      }
    }
    .padding(.leading, 32)
  }

  /// "Ran git status" for one step, "5 steps · Bash, Read" for several.
  private var summary: String {
    if tools.count == 1, case .tool(let name, let detail) = tools[0].kind {
      return detail.isEmpty ? name : "\(name) · \(detail)"
    }
    var names: [String] = []
    for tool in tools {
      if case .tool(let name, _) = tool.kind, !names.contains(name) { names.append(name) }
    }
    return "\(tools.count) steps · " + names.prefix(4).joined(separator: ", ")
  }
}

// MARK: - ChatComposer

private struct ChatComposer: View {
  @Binding var draft: String
  let sendFailed: Bool
  let onSend: () -> Void

  @FocusState private var isFocused: Bool
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Message the agent", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.geist(size: 13))
          .lineLimit(1...8)
          .focused($isFocused)
          .onKeyPress(.return, phases: .down) { press in
            // Return sends; Shift+Return adds a line.
            if press.modifiers.contains(.shift) { return .ignored }
            onSend()
            return .handled
          }
        Button(action: onSend) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.brandPrimary(from: runtimeTheme)))
        }
        .buttonStyle(.plain)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Send (Return). Shift+Return for a new line.")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(
            isFocused ? Color.brandPrimary(from: runtimeTheme).opacity(0.6) : Color.primary.opacity(0.08),
            lineWidth: 1)
      )
      if sendFailed {
        Text("Could not reach the session's terminal. Open the Terminal tab once, then try again.")
          .font(.secondaryCaption)
          .foregroundStyle(.orange)
      }
    }
    .padding(DesignTokens.Spacing.md)
    // Take the keyboard when the chat shows, and again once the hidden terminal
    // underneath has launched (it grabs focus when it starts).
    .task {
      isFocused = true
      try? await Task.sleep(for: .milliseconds(700))
      isFocused = true
    }
  }
}

// MARK: - TranscriptFileWatcher

/// Calls `onChange` when the transcript file is written to (kqueue via DispatchSource).
private struct TranscriptFileWatcher: NSViewRepresentable {
  let path: String?
  let onChange: () -> Void

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onChange = onChange
    context.coordinator.watch(path)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var onChange: () -> Void = {}
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?

    func watch(_ path: String?) {
      guard path != watchedPath else { return }
      stop()
      watchedPath = path
      guard let path else { return }
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { return }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .main)
      source.setEventHandler { [weak self] in self?.onChange() }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      self.source = source
    }

    func stop() {
      source?.cancel()
      source = nil
      watchedPath = nil
    }
  }
}

// MARK: - Copy

enum ChatClipboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// Fenced code blocks in a message, so each command can be copied in one click.
enum ChatCodeBlocks {
  struct Block: Equatable {
    let code: String
    var preview: String {
      let first = code.split(separator: "\n").first.map(String.init) ?? code
      return first.count > 60 ? String(first.prefix(59)) + "…" : first
    }
  }

  static func extract(from markdown: String) -> [Block] {
    var blocks: [Block] = []
    var current: [String]?
    for line in markdown.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if let lines = current {
          let code = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
          if !code.isEmpty { blocks.append(Block(code: code)) }
          current = nil
        } else {
          current = []
        }
      } else if current != nil {
        current?.append(line)
      }
    }
    return blocks
  }
}

private struct CopyChip: View {
  let label: String?
  let value: String
  let monospaced: Bool
  @State private var didCopy = false

  var body: some View {
    Button {
      ChatClipboard.copy(value)
      didCopy = true
    } label: {
      HStack(spacing: 5) {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          .font(.system(size: 10, weight: .semibold))
        if let label {
          Text(label)
            .font(monospaced ? .jetBrainsMono(size: 11) : .secondarySmall)
            .lineLimit(1)
        }
      }
      .foregroundStyle(didCopy ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label == nil ? "Copy message" : "Copy this code")
    .task(id: didCopy) {
      guard didCopy else { return }
      try? await Task.sleep(for: .seconds(1.5))
      didCopy = false
    }
  }
}

// MARK: - Quick replies

struct QuickReply: Identifiable, Equatable {
  let label: String
  let message: String
  var id: String { label }

  /// Answers for a message that ends in a question: its numbered options (up to
  /// four) when it lists them, plus a plain yes and no.
  static func replies(for text: String) -> [QuickReply] {
    let paragraphs = text.components(separatedBy: "\n\n").filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let tail = paragraphs.suffix(3).joined(separator: "\n\n") as String?,
      tail.contains("?")
    else { return [] }
    var replies: [QuickReply] = []
    for line in tail.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let match = trimmed.range(of: #"^([1-9])[\.\)]\s+"#, options: .regularExpression)
      else { continue }
      let number = String(trimmed[match].prefix(1))
      let option = trimmed[match.upperBound...]
        .replacingOccurrences(of: "**", with: "")
      let short = option.count > 32 ? String(option.prefix(31)) + "…" : option
      replies.append(QuickReply(label: "\(number) · \(short)", message: number))
      if replies.count == 4 { break }
    }
    replies.append(QuickReply(label: "Yes, go ahead", message: "Yes, go ahead."))
    replies.append(QuickReply(label: "No", message: "No."))
    return replies
  }
}

private struct QuickReplyBar: View {
  let replies: [QuickReply]
  let onSelect: (String) -> Void
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(replies) { reply in
          Button(reply.label) { onSelect(reply.message) }
            .buttonStyle(.plain)
            .font(.secondaryDefault)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
              Capsule().fill(Color.brandPrimary(from: runtimeTheme).opacity(0.12)))
            .overlay(
              Capsule().strokeBorder(Color.brandPrimary(from: runtimeTheme).opacity(0.3), lineWidth: 1))
            .help("Send \"\(reply.message)\"")
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.top, DesignTokens.Spacing.sm)
    }
    .scrollIndicators(.never)
  }
}

// MARK: - ChatMarkdownText

/// Fast markdown for chat: inline styles (bold, italic, `code`, links) through
/// Foundation's parser, fenced code as monospaced blocks. Line breaks are kept.
struct ChatMarkdownText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .prose(let prose):
          Text(Self.inline(prose))
            .font(.geist(size: 13))
            .lineSpacing(3)
        case .code(let code):
          Text(code)
            .font(.jetBrainsMono(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
      }
    }
  }

  enum Segment: Equatable {
    case prose(String)
    case code(String)
  }

  static func segments(of text: String) -> [Segment] {
    var segments: [Segment] = []
    var prose: [String] = []
    var code: [String]?
    func flushProse() {
      let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { segments.append(.prose(joined)) }
      prose = []
    }
    for line in text.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if let lines = code {
          segments.append(.code(lines.joined(separator: "\n")))
          code = nil
        } else {
          flushProse()
          code = []
        }
      } else if code != nil {
        code?.append(line)
      } else {
        prose.append(line)
      }
    }
    if let lines = code { segments.append(.code(lines.joined(separator: "\n"))) }
    flushProse()
    return segments
  }

  /// Inline markdown with line breaks preserved; headings shown as bold lines.
  static func inline(_ prose: String) -> AttributedString {
    let normalized = prose.components(separatedBy: "\n").map { line -> String in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { return line }
      let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
      return title.isEmpty ? line : "**\(title)**"
    }.joined(separator: "\n")
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(prose)
  }
}
