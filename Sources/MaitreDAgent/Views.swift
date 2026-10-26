import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 12)
                .frame(height: 38)
            Divider()
            if !store.inbox.isEmpty {
                Inbox()
                Divider()
            }
            if store.agents.isEmpty && store.config.customGroups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.title2).foregroundStyle(.tertiary)
                    Text(store.copy.emptyState).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.groups) { group in
                            GroupSection(group: group)
                        }
                        GroupEndDropZone()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            if !store.hooksInstalled || store.lastError != nil {
                NoticeBanner()
            }
            Divider()
            MessageFeed()
        }
        .frame(minWidth: 280, minHeight: 220)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(spacing: 8) {
            Text(store.copy.panelTitle).font(.headline)
            if store.needsCount > 0 {
                Label("\(store.needsCount)", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
                    .help(store.copy.needsCountHelp(store.needsCount))
            }
            if store.workingCount > 0 {
                Label("\(store.workingCount)", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .help(store.copy.workingCountHelp(store.workingCount))
            }
            Spacer()
            Button {
                store.config.pinned.toggle()
            } label: {
                Image(systemName: store.config.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(store.config.pinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(store.config.pinned ? "Unpin: hide when clicking elsewhere" : "Pin: keep floating on top, on this desktop")
            SettingsMenu()
        }
        .font(.callout.monospacedDigit())
        .labelStyle(CompactLabelStyle())
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

private struct SettingsMenu: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Menu {
            Toggle("Notify when an agent needs me", isOn: $store.config.notifications)
            Toggle("Open the exact session tab in VS Code", isOn: $store.config.deepLink)
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            ))
            Toggle("Pretentious mode", isOn: $store.config.pretentious)
            Divider()
            Button(store.copy.newGroup) { store.createGroup() }
            Divider()
            Button(store.hooksInstalled ? "Reinstall Claude Hooks" : "Install Claude Hooks") { store.installHooks() }
            if store.hooksInstalled {
                Button("Uninstall Claude Hooks") { store.uninstallHooks() }
            }
            Divider()
            Button(store.copy.quit) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct NoticeBanner: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            if let error = store.lastError {
                Text(error).font(.caption)
            } else {
                Text(store.copy.hooksMissing)
                    .font(.caption)
                Spacer(minLength: 4)
                Button("Install") { store.installHooks() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.08))
    }
}

// MARK: - Inbox

/// Open flags, newest first, above the agent list.
private struct Inbox: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let items = store.inbox
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full.fill").font(.system(size: 9))
                Text(store.copy.inboxTitle).fontWeight(.semibold)
                Spacer()
                Text("\(items.count)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.orange)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.flag.id) { item in
                        InboxItem(flag: item.flag, agent: item.agent)
                        if item.flag.id != items.last?.flag.id { Divider().opacity(0.5) }
                    }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color.orange.opacity(0.06))
    }
}

private struct InboxItem: View {
    @EnvironmentObject private var store: Store
    let flag: Flag
    let agent: Agent
    @State private var expanded = false
    @State private var truncated = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(.orange)
                Text(flag.raisedByName).fontWeight(.medium)
                if !flag.isSelf {
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Text(flag.subjectName).fontWeight(.medium)
                }
                Spacer()
                if hovering {
                    Button { store.dismissFlag(flag) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help(store.copy.dismissOne)
                } else {
                    Text(ago(flag.createdAt)).foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            ClampedText(text: flag.message, lines: 3, expanded: expanded, truncated: $truncated)
                .font(.callout)

            if truncated || expanded {
                Button(expanded ? store.copy.showLess : store.copy.showMore) {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(hovering ? 0.05 : 0))
        .onHover { hovering = $0 }
        .onTapGesture { store.focus(agent) }
        .help(store.copy.goTo(agent.name))
    }
}

/// Text limited to `lines`, reporting whether the limit actually cut anything off.
private struct ClampedText: View {
    let text: String
    let lines: Int
    let expanded: Bool
    @Binding var truncated: Bool

    var body: some View {
        Text(text)
            .lineLimit(expanded ? nil : lines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { shown in
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: shown.size.width, alignment: .leading)
                        .hidden()
                        .background(GeometryReader { full in
                            Color.clear
                                .onAppear { measure(full: full.size.height, shown: shown.size.height) }
                                .onChange(of: full.size.height) { _, height in measure(full: height, shown: shown.size.height) }
                                .onChange(of: shown.size.height) { _, height in measure(full: full.size.height, shown: height) }
                        })
                }
            )
    }

    private func measure(full: CGFloat, shown: CGFloat) {
        guard !expanded else { return }
        let cut = full > shown + 1
        if cut != truncated { truncated = cut }
    }
}

// MARK: - Groups

private struct GroupSection: View {
    @EnvironmentObject private var store: Store
    let group: AgentGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            GroupHeader(group: group)
            if !store.config.collapsed.contains(group.id) {
                ForEach(group.agents) { agent in
                    AgentRow(agent: agent, group: group, dimmed: group.hasLead && !store.isLead(agent) && agent.status != .needsMe)
                }
                if group.agents.isEmpty {
                    EmptyGroupDropZone(group: group)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct GroupHeader: View {
    @EnvironmentObject private var store: Store
    let group: AgentGroup
    @State private var targeted = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var collapsed: Bool { store.config.collapsed.contains(group.id) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            if store.editingGroupId == group.id {
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .focused($editing)
                    .onAppear {
                        draft = group.title
                        editing = true
                    }
                    .onSubmit(commit)
                    .onExitCommand { store.editingGroupId = nil }
                    .onChange(of: editing) { _, focused in if !focused { commit() } }
            } else {
                Text(group.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if group.isCustom {
                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if collapsed {
                if group.needsCount > 0 {
                    Text("\(group.needsCount)").foregroundStyle(.orange)
                }
                Text("\(group.agents.count)").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(targeted ? 0.15 : 0)))
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { store.toggleCollapsed(group.id) } }
        .draggable("group:\(group.id)") {
            Text(group.title).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, group: group, before: nil)
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Rename…") { store.editingGroupId = group.id }
            Button(collapsed ? "Expand" : "Collapse") { store.toggleCollapsed(group.id) }
            Divider()
            Button("Move Up") { store.shiftGroup(group.id, by: -1) }
                .disabled(store.groups.first?.id == group.id)
            Button("Move Down") { store.shiftGroup(group.id, by: 1) }
                .disabled(store.groups.last?.id == group.id)
            if group.isCustom {
                Divider()
                Button(store.copy.deleteGroup) { store.deleteGroup(group.id) }
            }
        }
    }

    private func commit() {
        guard store.editingGroupId == group.id else { return }
        store.renameGroup(group.id, to: draft)
        store.editingGroupId = nil
    }
}

private struct EmptyGroupDropZone: View {
    @EnvironmentObject private var store: Store
    let group: AgentGroup
    @State private var targeted = false

    var body: some View {
        Text(store.copy.dropHere)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            )
            .padding(.horizontal, 6)
            .dropDestination(for: String.self) { items, _ in
                store.handleDrop(items, group: group, before: nil)
            } isTargeted: { targeted = $0 }
    }
}

/// Dropping a group here moves it to the end of the list.
private struct GroupEndDropZone: View {
    @EnvironmentObject private var store: Store
    @State private var targeted = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(targeted ? 0.5 : 0))
            .frame(height: targeted ? 2 : 12)
            .dropDestination(for: String.self) { items, _ in
                let groupIds = items.filter { $0.hasPrefix("group:") }.map { String($0.dropFirst(6)) }
                groupIds.forEach { store.moveGroup($0, before: nil) }
                return !groupIds.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

// MARK: - Agent row

private struct AgentRow: View {
    @EnvironmentObject private var store: Store
    let agent: Agent
    let group: AgentGroup
    let dimmed: Bool
    @State private var hovering = false
    @State private var targeted = false
    @State private var flash = false

    private var isLead: Bool { store.isLead(agent) }

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(status: agent.status, label: store.copy.status(agent.status)
                + (agent.backgroundShell ? " · \(store.copy.backgroundShell)" : ""))
            HStack(spacing: 5) {
                if isLead {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
                Text(agent.name)
                    .fontWeight(isLead ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Tooltips sit on the parts, not the row: a row-level .help hides the inner ones.
                    .help("\(agent.cwd)\n\(store.copy.status(agent.status))\(agent.waitReason.map { " · \(store.copy.reason($0))" } ?? "")")
                if agent.remoteControl {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(store.copy.remoteControl)
                }
                if agent.status == .needsMe, let reason = agent.waitReason {
                    Text(store.copy.reason(reason))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let flag = agent.flags.last {
                    FlagLabel(text: store.copy.flagLine(flag), extra: agent.flags.count - 1)
                        .help(store.copy.flagHelp(agent.flags))
                }
                Spacer(minLength: 4)
                if hovering && !agent.flags.isEmpty {
                    Button {
                        store.dismissFlags(of: agent)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(store.copy.dismissFlags(agent.flags.count))
                }
                MessageBadges(sent: store.sentCounts[agent.name] ?? 0, received: store.receivedCounts[agent.name] ?? 0, copy: store.copy)
                if let context = agent.context {
                    ContextRing(usage: context)
                        .padding(3)
                        .contentShape(Rectangle())
                        .help(store.copy.contextHelp(context))
                }
                Text(shortDuration(store.now.timeIntervalSince(agent.since)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
            .opacity(dimmed ? 0.5 : 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(flash ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .overlay(alignment: .top) {
            if targeted {
                Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -1)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture { store.focus(agent) }
        .draggable("agent:\(agent.key)") {
            Text(agent.name).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, group: group, before: agent)
        } isTargeted: { targeted = $0 }
        .onChange(of: store.pulses[agent.name]) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { flash = true }
            withAnimation(.easeIn(duration: 1.2).delay(0.4)) { flash = false }
        }
        .contextMenu {
            if !agent.flags.isEmpty {
                Button(store.copy.dismissFlags(agent.flags.count)) { store.dismissFlags(of: agent) }
                Divider()
            }
            Button(store.copy.leadToggle(isLead: isLead)) { store.toggleLead(agent) }
            Menu(store.copy.moveToGroup) {
                ForEach(store.groups.filter { $0.id != group.id }) { target in
                    Button(target.title) { store.moveAgent(key: agent.key, to: target.id, before: nil) }
                }
                Divider()
                Button(store.copy.newGroupEllipsis) { store.createGroup(with: agent) }
            }
            Divider()
            Button("Open in VS Code") { store.focus(agent) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.cwd)])
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.sessionId, forType: .string)
            }
        }
    }
}

private struct FlagLabel: View {
    let text: String
    let extra: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flag.fill").font(.system(size: 8))
            Text(text).lineLimit(1).truncationMode(.tail)
            if extra > 0 { Text("+\(extra)").fontWeight(.semibold) }
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}

private struct MessageBadges: View {
    let sent: Int
    let received: Int
    let copy: Copy

    var body: some View {
        HStack(spacing: 4) {
            if sent > 0 { Text("↑\(sent)") }
            if received > 0 { Text("↓\(received)") }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .help(copy.badgeHelp(sent: sent, received: received))
    }
}

/// Context window fill as a small pie (a ring would read as the "working" spinner).
/// Turns orange once it's worth compacting.
private struct ContextRing: View {
    let usage: ContextUsage

    private var color: Color { usage.fraction >= 0.7 ? .orange : .secondary }

    var body: some View {
        ZStack {
            Circle().strokeBorder(color.opacity(0.6), lineWidth: 1)
            PieSlice(fraction: usage.fraction).fill(color).padding(2)
        }
        .frame(width: 12, height: 12)
    }
}

private struct PieSlice: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct StatusDot: View {
    let status: AgentStatus
    let label: String

    var body: some View {
        Group {
            switch status {
            case .needsMe: NeedsMeDot()
            case .working: WorkingDot()
            case .idle:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: 14)
        .help(label)
    }
}

private struct NeedsMeDot: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 9, height: 9)
            .background(
                Circle()
                    .stroke(Color.orange, lineWidth: 2)
                    .scaleEffect(animate ? 2 : 1)
                    .opacity(animate ? 0 : 0.7)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

private struct WorkingDot: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(animate ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

// MARK: - Message feed

private struct MessageFeed: View {
    @EnvironmentObject private var store: Store
    @State private var expandedId: String?

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { store.config.feedExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(store.config.feedExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(store.copy.messagesTitle).fontWeight(.medium)
                    Text(store.copy.messagesWindow).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(store.messages.count)").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.config.feedExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.messages.prefix(150)) { message in
                            MessageRow(message: message, expanded: expandedId == message.id)
                                .onTapGesture {
                                    expandedId = expandedId == message.id ? nil : message.id
                                }
                            Divider().opacity(0.5)
                        }
                        if store.messages.isEmpty {
                            Text(store.copy.noMessages)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(12)
                        }
                    }
                }
                .frame(height: 200)
            }
        }
    }
}

private struct MessageRow: View {
    let message: AgentMessage
    let expanded: Bool

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var headline: String {
        if !message.summary.isEmpty { return message.summary }
        return message.text.split(separator: "\n").first.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(message.fromName).fontWeight(.medium)
                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(message.toName).fontWeight(.medium)
                Spacer()
                Text(Self.time.string(from: message.date)).foregroundStyle(.tertiary)
            }
            .font(.caption.monospacedDigit())
            Text(headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 1)
            if expanded && !message.text.isEmpty {
                Text(message.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
