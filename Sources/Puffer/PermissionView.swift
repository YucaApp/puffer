import SwiftUI

/// Shown on launch until the Accessibility permission has been granted.
struct PermissionView: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Puffer needs Accessibility access")
                    .font(.title2.bold())
            }

            Text("""
            To expand a shortcode, Puffer has to notice you typing it in any app, \
            then delete it and insert your text in its place. macOS only lets an \
            app do that once you allow it under Accessibility.
            """)

            Text("""
            Puffer keeps only the most recent characters you typed (128 at \
            most), in memory, to spot shortcodes, and forgets them after ten \
            seconds without typing. \
            Nothing you type is stored or sent anywhere. Password fields that \
            use macOS secure input are hidden from Puffer; a password box that \
            does not use it, as on some web pages, looks like any other typing.
            """)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click Open System Settings.")
                Text("2. Switch on Puffer in the Accessibility list.")
                Text("3. Come back here. This window closes by itself.")
            }

            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for permission…").foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 480)
    }
}
