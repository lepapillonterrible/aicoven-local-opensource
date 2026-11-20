import SwiftUI

/// The shell's content pane: the thread open in the scope on screen, or
/// else the scope's Overview. Until the Overview itself is built, a scope
/// with no place open shows what the window showed there before: for Strix
/// the welcome, for a coven the prompt to start a conversation.
struct ShellContentView: View {
    @ObservedObject var navigator: ShellNavigator
    let onNewThread: () -> Void
    let onCreateCoven: () -> Void
    let onOpenProviderKeys: () -> Void

    var body: some View {
        Group {
            if let thread = navigator.place?.threadValue {
                // Its name is the window's title, so it shows none of its own.
                // Tied to the thread, so each thread has its own state.
                PersonalChatView(thread: thread, onEditAgent: nil, onBack: nil, showsHeader: false)
                    .id(thread.id)
            } else if navigator.selected == .strix {
                WelcomeToPersonalChat(onNewChat: onNewThread, onCreateCoven: onCreateCoven, onOpenProviderKeys: onOpenProviderKeys)
            } else {
                StartConversationPrompt(onCreateThread: onNewThread)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NebulaBackground())
    }
}

/// What a coven with nothing open shows: a prompt to start a thread.
struct StartConversationPrompt: View {
    var onCreateThread: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            IconBadge(icon: "message", size: 60, color: .aicovenTeal)
            VStack(spacing: Spacing.sm) {
                Text("Start a Conversation")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)
                Text("Create a new thread to chat with your AI agents")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            // Create Thread CTA button
            if let onCreateThread {
                GradientButton("New Thread", icon: "plus", style: .primary) {
                    onCreateThread()
                }
                .padding(.top, Spacing.md)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
