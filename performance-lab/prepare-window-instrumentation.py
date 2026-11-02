#!/usr/bin/env python3
"""Inject narrow diagnostics into the pinned upstream CI checkout, never its repo source."""
from pathlib import Path
import os
import re


def replace(path, before, after):
    file = Path(path)
    text = file.read_text()
    assert text.count(before) == 1, f'{path}: expected one pinned source hook: {before[:100]!r}'
    file.write_text(text.replace(before, after))


base = Path('performance-lab')
diagnostics = Path('OpenCodeIOSClient/Diagnostics/OpenClientPerformanceDiagnostics.swift')
diagnostics.write_text(diagnostics.read_text() + '\n' + (base / 'window_session_probe.swift').read_text())
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
# Scope native HTTP phases to the initial/refresh loader, leaving older-history
# callbacks separate. Each source version is instrumented at its own typed boundary.
session_file = Path(sessions)
source = session_file.read_text()
start = source.index('    func loadMessages(')
end = source.index('    func loadOlderMessages(', start)
method = source[start:end]
if '        let page: BackendTranscriptPage' in method:
    before = '        let page: BackendTranscriptPage'
    method = method.replace(before, '        OpenClientExtremeSessionProbe.record("canonical_request_started", sessionID: session.id, details: ["request_limit": messageLimit, "existing_messages": existingMessages.count])\n' + before, 1)
    before = '        guard !Task.isCancelled, isCurrentBackendConnection(connection)'
    assert method.count(before) == 1
    method = method.replace(before, '        OpenClientExtremeSessionProbe.record("canonical_typed_page_returned", sessionID: session.id, details: ["page_messages": page.messages.count])\n' + before, 1)
else:
    before = '        let page = try await connection.chat.transcript('
    assert method.count(before) == 1
    method = method.replace(before, '        OpenClientExtremeSessionProbe.record("canonical_request_started", sessionID: session.id, details: ["request_limit": messageLimit, "existing_messages": existingMessages.count])\n' + before, 1)
    before = '        guard !Task.isCancelled, isCurrentBackendConnection(connection)'
    assert method.count(before) == 1
    method = method.replace(before, '        OpenClientExtremeSessionProbe.record("canonical_typed_page_returned", sessionID: session.id, details: ["page_messages": page.messages.count])\n' + before, 1)
before = '        inferFunAndGames(from: loadedMessages, forSessionID: session.id)'
assert method.count(before) == 1
method = method.replace(before, '        OpenClientExtremeSessionProbe.canonicalPublished(sessionID: session.id, count: loadedMessages.count)\n' + before, 1)
session_file.write_text(source[:start] + method + source[end:])
facade = Path('OpenCodeIOSClient/Facades/ChatFacade.swift')
source = facade.read_text()
if os.environ.get('OPENCLIENT_WINDOW_VARIANT') == 'patched':
    start = source.index('        if viewModel.directoryStoreRegistry.canReuseLegacyTranscript(')
    point = source.index('            viewModel.chatStore.finishLoadingSelectedSession()', start)
    line = '            viewModel.chatStore.finishLoadingSelectedSession()'
    source = source[:point] + source[point:].replace(line, line + '\n            OpenClientExtremeSessionProbe.cacheReused(sessionID: session.id, count: owner.syncStore.messageCount(forSessionID: session.id))', 1)
    facade.write_text(source)
event = 'OpenCodeIOSClient/API/OpenCodeEventManager.swift'
replace(event, '            await Self.runStreamLoop(\n                client: client,\n                onStatus: onStatus,',
    '            await Self.runStreamLoop(\n                client: client,\n                onStatus: { status in\n                    await onStatus(status)\n                    if status.hasPrefix("stream open") { OpenClientExtremeSessionProbe.record("legacy_stream_open") }\n                },')
cache = 'OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel+LocalCache.swift'
warm_memory_hook = '''            // Memory already owns both slices; decoding the disk transcript would
            // not replace these messages. This does not make server data fresh.
            localCacheHydratedChatKeys.insert(runtimeKey)
            return nil'''
if warm_memory_hook in Path(cache).read_text():
    replace(cache, warm_memory_hook,
        warm_memory_hook.replace('            return nil',
            '            OpenClientExtremeSessionProbe.record("cache_hydration_skipped_warm_memory", sessionID: session.id, details: ["cache_messages": targetStore.syncStore.messageCount(forSessionID: session.id), "todos_known": initialTodos != nil])\n            return nil'))
replace(cache,
    '        let snapshot = await localChatSnapshot(\n            serverID: serverID,\n            sessionID: session.id,\n            consumesPrefetch: true\n        )',
    '        OpenClientExtremeSessionProbe.record("cache_hydration_started", sessionID: session.id)\n        let snapshot = await localChatSnapshot(\n            serverID: serverID,\n            sessionID: session.id,\n            consumesPrefetch: true\n        )\n        OpenClientExtremeSessionProbe.record("cache_snapshot_returned", sessionID: session.id, details: ["cache_messages": snapshot?.preparedMessages.messages.count ?? 0])')
replace(cache,
    '        if appliedMessages {\n            localCacheMessageRefreshedAtByKey[runtimeKey] = snapshot.messagesRefreshedAt\n        }',
    '        if appliedMessages {\n            localCacheMessageRefreshedAtByKey[runtimeKey] = snapshot.messagesRefreshedAt\n        }\n        OpenClientExtremeSessionProbe.record("cache_hydration_finished", sessionID: session.id, details: ["cache_messages": snapshot.preparedMessages.messages.count, "applied_messages": appliedMessages])')
disk = 'OpenCodeIOSClient/Persistence/SwiftDataOpenCodeLocalCacheRepository.swift'
disk_file = Path(disk)
source = disk_file.read_text()
for name, phase, result in [('loadChat', 'disk_cache_load', 'OpenCodeCachedChatSnapshot'),
                            ('loadChatPreview', 'disk_preview_load', 'OpenCodeCachedChatPreview')]:
    pattern = r'(    func ' + name + r'\([^{}]*?\) async throws -> ' + result + r'\? \{)'
    match = re.search(pattern, source)
    if name == 'loadChatPreview' and os.environ.get('OPENCLIENT_WINDOW_VARIANT') != 'patched':
        continue
    assert match, f'Missing disk hook: {name}'
    source = source[:match.end()] + f'\n        OpenClientExtremeSessionProbe.record("{phase}_started", sessionID: sessionID)\n        defer {{ OpenClientExtremeSessionProbe.record("{phase}_finished", sessionID: sessionID) }}' + source[match.end():]
disk_file.write_text(source)
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
seed = (base / 'window_seed_cache.swift').read_text()
if os.environ.get('OPENCLIENT_WINDOW_VARIANT') == 'patched':
    seed = seed.replace('        // WINDOW_PREVIEW_READBACK', '''        let loadedPreview = try await readRepository.loadChatPreview(serverID: config.recentServerID, sessionID: "ses_extreme")\n        let preview = try XCTUnwrap(loadedPreview)
        XCTAssertEqual(preview.snapshot.preparedMessages.messages.count, min(count, 400))
        XCTAssertEqual(preview.retainedMessageCount, count)
        XCTAssertTrue(preview.hasRetainedHistory)
        XCTAssertEqual(preview.hasOlderMessages, count > 400)
        result["readback_preview_messages"] = preview.snapshot.preparedMessages.messages.count
        result["readback_preview_retained_messages"] = preview.retainedMessageCount
        result["readback_preview_has_retained_history"] = preview.hasRetainedHistory''')
unit.write_text(unit.read_text() + '\n' + seed)
ui = Path('OpenCodeIOSClientUITests/ToolGroupingUITests.swift')
ui.write_text(ui.read_text() + '\n' + (base / 'long_transcript_ui.swift').read_text() + '\n' + (base / 'window_session_ui.swift').read_text())
print('Injected pinned extreme-session diagnostics, seed setup, and native UI loading test.')
