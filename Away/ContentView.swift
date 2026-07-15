import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: OscarClient

    var body: some View {
        NavigationStack {
            if client.isReady {
                BuddyListView()
            } else {
                LoginView()
            }
        }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var client: OscarClient
    @State private var showsPassword = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle()
                        .fill(client.isConnecting ? Color.orange : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(client.status)
                        .font(.headline)
                }
            }

            Section("Server") {
                TextField("Host", text: $client.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $client.port)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Login") {
                TextField("Screen name", text: $client.screenName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Group {
                        if showsPassword {
                            TextField("Password", text: $client.password)
                        } else {
                            SecureField("Password", text: $client.password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)

                    Button {
                        showsPassword.toggle()
                    } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Button {
                    client.connect()
                } label: {
                    Label(client.isConnecting ? "Signing On" : "Sign On", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(client.isConnecting || client.screenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Status") {
                ForEach(client.messages.filter { $0.direction == .system }) { message in
                    Text(message.text)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Away")
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct BuddyListView: View {
    @EnvironmentObject private var client: OscarClient

    private var onlineBuddies: [String] {
        client.buddies.filter { client.isBuddyOnline($0) }
    }

    private var offlineBuddies: [String] {
        client.buddies.filter { !client.isBuddyOnline($0) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                    Text(client.screenName)
                        .font(.headline)
                    Spacer()
                    Button("Sign Off", role: .destructive) {
                        client.disconnect()
                    }
                }
            }

            Section("Add Buddy") {
                HStack {
                    TextField("Screen name", text: $client.buddyName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        client.addBuddy()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Chat Rooms") {
                HStack {
                    TextField("Room name", text: $client.roomName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        client.joinRoom()
                    } label: {
                        Image(systemName: "plus.bubble.fill")
                    }
                    .buttonStyle(.borderless)
                }

                if client.chatRooms.isEmpty {
                    Text("No rooms joined")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(client.chatRooms) { room in
                        NavigationLink {
                            RoomChatView(room: room)
                        } label: {
                            HStack {
                                Image(systemName: "person.3.fill")
                                    .foregroundStyle(.blue)
                                Text(room.name)
                                Spacer()
                                Text("\(room.participants.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Leave", role: .destructive) {
                                client.leaveRoom(room)
                            }
                        }
                    }
                }
            }

            Section("Online (\(onlineBuddies.count))") {
                if onlineBuddies.isEmpty {
                    Text("No buddies online")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(onlineBuddies, id: \.self) { buddy in
                        NavigationLink {
                            ChatView(buddy: buddy)
                        } label: {
                            BuddyRow(buddy: buddy, isOnline: true)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                client.removeBuddy(buddy)
                            }
                        }
                    }
                }
            }

            Section("Offline (\(offlineBuddies.count))") {
                if offlineBuddies.isEmpty {
                    Text("No buddies offline")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(offlineBuddies, id: \.self) { buddy in
                        NavigationLink {
                            ChatView(buddy: buddy)
                        } label: {
                            BuddyRow(buddy: buddy, isOnline: false)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                client.removeBuddy(buddy)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Buddy List")
    }
}

private struct BuddyRow: View {
    let buddy: String
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
            Text(buddy)
            Spacer()
            Text(isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RoomChatView: View {
    @EnvironmentObject private var client: OscarClient
    let room: ChatRoom

    private var currentRoom: ChatRoom {
        client.chatRooms.first { $0.id == room.id } ?? room
    }

    private var roomMessages: [ChatRoomMessage] {
        client.messages(in: currentRoom)
    }

    var body: some View {
        List {
            Section("People (\(currentRoom.participants.count))") {
                if currentRoom.participants.isEmpty {
                    Text("No participant list yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentRoom.participants, id: \.self) { participant in
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text(participant)
                        }
                    }
                }
            }

            Section("Room") {
                if roomMessages.isEmpty {
                    Text("No room messages yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(roomMessages) { message in
                        ChatBubble(
                            sender: message.from,
                            text: message.text,
                            isOutgoing: message.isOutgoing
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }

        }
        .navigationTitle(currentRoom.name)
        .toolbar {
            Button("Leave", role: .destructive) {
                client.leaveRoom(currentRoom)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            ComposerBar(
                placeholder: "Message",
                text: $client.roomDraftMessage,
                title: "Send",
                isDisabled: client.roomDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                client.sendRoomMessage(room: currentRoom)
            }
        }
    }
}

private struct ChatView: View {
    @EnvironmentObject private var client: OscarClient
    let buddy: String

    private var chatMessages: [IncomingMessage] {
        client.messages(with: buddy)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Circle()
                        .fill(client.isBuddyOnline(buddy) ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(client.isBuddyOnline(buddy) ? "Online" : "Offline")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Messages") {
                if chatMessages.isEmpty {
                    Text("No messages yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chatMessages) { message in
                        ChatBubble(
                            sender: message.from,
                            text: message.text,
                            isOutgoing: message.direction == .outgoing
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }

        }
        .navigationTitle(buddy)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            client.chooseBuddy(buddy)
        }
        .safeAreaInset(edge: .bottom) {
            ComposerBar(
                placeholder: "Message",
                text: $client.draftMessage,
                title: "Send",
                isDisabled: client.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                client.chooseBuddy(buddy)
                client.sendMessage()
            }
        }
    }
}

private struct ComposerBar: View {
    let placeholder: String
    @Binding var text: String
    let title: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button(action: action) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(isDisabled)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}

private struct ChatBubble: View {
    let sender: String
    let text: String
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing {
                Spacer(minLength: 48)
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(sender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.body)
                    .foregroundStyle(isOutgoing ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isOutgoing ? Color.blue : Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: 290, alignment: isOutgoing ? .trailing : .leading)

            if !isOutgoing {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environmentObject(OscarClient())
}
