//
//  FreeDocxApp.swift
//  FreeDocx
//
//  Created by Siavash Bonakdar on 8/30/26.
//

import AppKit
import SwiftUI
import os

enum FreeDocxLifecycleState {
    nonisolated private static let state = OSAllocatedUnfairLock(initialState: false)

    nonisolated static var hasStartedDocument: Bool {
        state.withLock { $0 }
    }

    nonisolated static func documentDidStartOpening() {
        state.withLock { $0 = true }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // On current macOS releases, the Open panel is hosted outside this
        // process, so it cannot be found in NSApplication.windows. Ignore the
        // documentless transition at launch; after a document has started
        // opening, closing its final window should terminate the app.
        return FreeDocxLifecycleState.hasStartedDocument
    }
}

@main
struct FreeDocxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { FreeDocxDocument() }) { file in
            ContentView(document: file.document)
        }
        .commands {
            EditorFindCommands()
        }
    }
}

private struct EditorFindCommands: Commands {
    @FocusedObject private var controller: RichTextEditorController?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { controller?.performFindAction(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find and Replace…") {
                    controller?.performFindAction(.showReplaceInterface)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Find Next") { controller?.performFindAction(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { controller?.performFindAction(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") {
                    controller?.performFindAction(.setSearchString)
                }
                .keyboardShortcut("e", modifiers: .command)
            }
            .disabled(controller == nil)
        }
    }
}
