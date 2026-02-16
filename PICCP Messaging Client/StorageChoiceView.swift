import SwiftUI

struct StorageChoiceView: View {
    let onSelect: (StorageProtectionMode) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Choose Storage Protection")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Pick how the app stores local data and attachments. You can change this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                VStack(spacing: 12) {
                    Button {
                        onSelect(.keychain)
                    } label: {
                        StorageOptionRow(
                            title: "Use Keychain (Recommended)",
                            subtitle: StorageProtectionMode.keychain.descriptionText,
                            systemImage: "key.fill"
                        )
                    }
                    .glassButton(prominent: true)

                    Button {
                        onSelect(.deviceOnly)
                    } label: {
                        StorageOptionRow(
                            title: "Continue without Keychain",
                            subtitle: StorageProtectionMode.deviceOnly.descriptionText,
                            systemImage: "internaldrive"
                        )
                    }
                    .glassButton()
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.9)
            )
            .padding()
        }
        .ignoresSafeArea()
    }
}

private struct StorageOptionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
