#!/usr/bin/env python3
"""Inject narrow diagnostics into the pinned upstream CI checkout, never its repo source."""
from pathlib import Path


def replace(path, before, after):
    file = Path(path)
    text = file.read_text()
    assert text.count(before) == 1, f'{path}: expected one pinned source hook: {before[:100]!r}'
    file.write_text(text.replace(before, after))


base = Path('performance-lab')
diagnostics = Path('OpenCodeIOSClient/Diagnostics/OpenClientPerformanceDiagnostics.swift')
diagnostics.write_text(diagnostics.read_text() + '\n' + (base / 'extreme_session_probe.swift').read_text())
replace('OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel.swift',
    '        if configureUITestEnvironmentIfNeeded() {\n            return\n        }',
    '        if configureUITestEnvironmentIfNeeded() {\n            OpenClientExtremeSessionProbe.configureAppearance(appearanceStore)\n            return\n        }')
replace('OpenCodeIOSClient/Views/Root/RootView.swift',
    '        .task {\n#if DEBUG\n            if !didRunUITestAutoConnect,',
    '        .task {\n#if DEBUG\n            if ProcessInfo.processInfo.environment["OPENCLIENT_EXTREME_SEED_ONLY"] == "1" { return }\n            if !didRunUITestAutoConnect,')
replace('OpenCodeIOSClient/Views/Root/RootView.swift',
    '        .onChange(of: shell.isShowingConnectionOverlay) { _, isShowing in\n            guard !isShowing else { return }',
    '        .onChange(of: shell.isShowingConnectionOverlay) { _, isShowing in\n            guard !isShowing else { return }\n            OpenClientExtremeSessionProbe.record("connection_overlay_dismissed", details: ["connected_actual": shell.isConnected])')
# The DEBUG parent tag propagates over native transcript/composer identifiers.
# Remove that diagnostic tag only; Release has no tag and routing stays intact.
replace('OpenCodeIOSClient/Views/Root/RootView.swift',
    '            #if DEBUG\n            .accessibilityIdentifier("navigation.chat.\\(route.sessionID)")\n',
    '            #if DEBUG\n')
replace('OpenCodeIOSClient/Facades/ActivityFacade.swift',
    '                    store.applyCachedMessageState(snapshot.preparedMessages, forSessionID: result.session.id)',
    '                    store.applyCachedMessageState(snapshot.preparedMessages, forSessionID: result.session.id)\n                    OpenClientExtremeSessionProbe.record("startup_cache_published", sessionID: result.session.id, details: ["loaded_messages": store.syncStore.messageCount(forSessionID: result.session.id)])')
sessions = 'OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel+Sessions.swift'
replace(sessions, '    func beginSessionNavigation(_ session: OpenCodeSession) -> String? {\n',
    '    func beginSessionNavigation(_ session: OpenCodeSession) -> String? {\n        OpenClientExtremeSessionProbe.beginSelection(sessionID: session.id)\n')
replace(sessions,
    '        let page = try await connection.chat.transcript(sessionID: session.id,\n            scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID), cursor: nil, limit: messageLimit)',
    '        OpenClientExtremeSessionProbe.record("canonical_request_started", sessionID: session.id, details: ["request_limit": messageLimit, "existing_messages": existingMessages.count])\n        let page = try await connection.chat.transcript(sessionID: session.id,\n            scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID), cursor: nil, limit: messageLimit)\n        OpenClientExtremeSessionProbe.record("canonical_typed_page_returned", sessionID: session.id, details: ["page_messages": page.messages.count])')
replace(sessions,
    '\n        chatStore.applyMessageHistoryPage(nextCursor: page.olderCursor, forSessionID: session.id)\n',
    '\n        chatStore.applyMessageHistoryPage(nextCursor: page.olderCursor, forSessionID: session.id)\n        OpenClientExtremeSessionProbe.canonicalPublished(sessionID: session.id, count: loadedMessages.count)\n')
cache = 'OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel+LocalCache.swift'
replace(cache,
    '        let snapshot = await localChatSnapshot(\n            serverID: serverID,\n            sessionID: session.id,\n            consumesPrefetch: true\n        )',
    '        OpenClientExtremeSessionProbe.record("cache_hydration_started", sessionID: session.id)\n        let snapshot = await localChatSnapshot(\n            serverID: serverID,\n            sessionID: session.id,\n            consumesPrefetch: true\n        )\n        OpenClientExtremeSessionProbe.record("cache_snapshot_returned", sessionID: session.id, details: ["cache_messages": snapshot?.preparedMessages.messages.count ?? 0])')
replace(cache,
    '        if appliedMessages {\n            localCacheMessageRefreshedAtByKey[runtimeKey] = snapshot.messagesRefreshedAt\n        }',
    '        if appliedMessages {\n            localCacheMessageRefreshedAtByKey[runtimeKey] = snapshot.messagesRefreshedAt\n        }\n        OpenClientExtremeSessionProbe.record("cache_hydration_finished", sessionID: session.id, details: ["cache_messages": snapshot.preparedMessages.messages.count, "applied_messages": appliedMessages])')
disk = 'OpenCodeIOSClient/Persistence/SwiftDataOpenCodeLocalCacheRepository.swift'
replace(disk,
    '    ) async throws -> OpenCodeCachedChatSnapshot? {\n        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])',
    '    ) async throws -> OpenCodeCachedChatSnapshot? {\n        OpenClientExtremeSessionProbe.record("disk_cache_load_started", sessionID: sessionID)\n        defer { OpenClientExtremeSessionProbe.record("disk_cache_load_finished", sessionID: sessionID) }\n        let key = OpenCodeLocalCacheKey.make([serverID, sessionID])')
replace(disk,
    '        let todos = record.todosPayload\n            .flatMap { try? decode([OpenCodeTodo].self, from: $0) }',
    '        OpenClientExtremeSessionProbe.record("disk_cache_json_decoded", sessionID: sessionID, details: ["cache_messages": messages?.count ?? 0, "cache_payload_bytes": record.messagesPayload?.count ?? 0])\n        let todos = record.todosPayload\n            .flatMap { try? decode([OpenCodeTodo].self, from: $0) }')
chat = 'OpenCodeIOSClient/Views/Chat/ChatView.swift'
replace(chat,
    '            if let hiddenAt = initialPresentationHiddenAt {\n                OpenClientSessionSwitchLog.log(',
    '            OpenClientExtremeSessionProbe.revealStarted(rows: rows.count)\n            if let hiddenAt = initialPresentationHiddenAt {\n                OpenClientSessionSwitchLog.log(')
replace(chat,
    '                      self.initialRevealGeneration == revealGeneration else { return }\n                // Give a pending sidebar switch priority',
    '                      self.initialRevealGeneration == revealGeneration else { return }\n                OpenClientExtremeSessionProbe.revealCompleted()\n                // Give a pending sidebar switch priority')
replace(chat,
    '    private func refreshChatDataFromBottomOverscroll() async {\n        guard !isRefreshingChatData else { return }',
    '    private func refreshChatDataFromBottomOverscroll() async {\n        guard !isRefreshingChatData else { return }\n        OpenClientExtremeSessionProbe.beginRefresh(sessionID: sessionID)')
replace(chat,
    '        await chatFacade.refreshChatData(for: sessionID)\n    }',
    '        await chatFacade.refreshChatData(for: sessionID)\n        OpenClientExtremeSessionProbe.refreshCompleted(sessionID: sessionID)\n    }')
replace('OpenCodeIOSClient/Views/Chat/MessageComposer.swift',
    '            parent.onMentionsChange(mentions)\n\n            guard let textView = textView as? ComposerPlaceholderTextView else { return }',
    '            parent.onMentionsChange(mentions)\n            OpenClientExtremeSessionProbe.inputChanged(textView.text ?? "")\n\n            guard let textView = textView as? ComposerPlaceholderTextView else { return }')
unit = Path('OpenCodeIOSClientTests/OpenCodeLocalCacheRepositoryTests.swift')
unit.write_text(unit.read_text() + '\n' + (base / 'extreme_seed_cache.swift').read_text())
ui = Path('OpenCodeIOSClientUITests/ToolGroupingUITests.swift')
ui.write_text(ui.read_text() + '\n' + (base / 'long_transcript_ui.swift').read_text() + '\n' + (base / 'extreme_session_ui.swift').read_text())
print('Injected pinned extreme-session diagnostics, seed setup, and native UI loading test.')
