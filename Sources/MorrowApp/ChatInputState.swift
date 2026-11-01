import SwiftUI

/// Keystrokes invalidate only the input controls, not the mailbox, contact
/// workspace or rendered conversation history on the shared AppModel.
@MainActor final class ChatInputState: ObservableObject {
    @Published var text = ""
}

struct ChatInputObservation<Content: View>: View {
    @ObservedObject var input: ChatInputState
    @ViewBuilder var content: (String) -> Content
    var body: some View { content(input.text) }
}
