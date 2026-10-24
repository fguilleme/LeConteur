import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareImportView(context: extensionContext))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct ShareImportView: View {
    let context: NSExtensionContext?
    @State private var isDone = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "book.closed.fill")
                .font(.system(size: 58)).foregroundStyle(Color(red: 0.22, green: 0.34, blue: 0.26))
            Text("Le Conteur").font(.system(size: 34, weight: .medium, design: .serif))
            if let error {
                Text(error).multilineTextAlignment(.center)
            } else if isDone {
                Text("Votre livre vous attend.").font(.title2)
                Text("Ouvrez Le Conteur pour l’ajouter à votre bibliothèque et commencer la lecture.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                ProgressView("Copie sur votre iPhone…")
            }
            if isDone || error != nil {
                Button("Terminer") { context?.completeRequest(returningItems: nil) }
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.22, green: 0.34, blue: 0.26))
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .task { await receive() }
    }

    private func receive() async {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        let supported = ["org.idpf.epub-container", UTType.pdf.identifier, UTType.plainText.identifier, UTType.fileURL.identifier]
        guard let provider = items.flatMap({ $0.attachments ?? [] }).first,
              let type = supported.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            error = "Partagez un fichier EPUB, PDF ou TXT avec Le Conteur."
            return
        }
        do {
            let suggestedName = provider.suggestedName
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if type == UTType.fileURL.identifier {
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, failure in
                        guard let url = item as? URL else {
                            continuation.resume(throwing: failure ?? CocoaError(.fileReadUnknown)); return
                        }
                        do { try SharedInbox.stage(url); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                    return
                }
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, failure in
                    guard let url else {
                        continuation.resume(throwing: failure ?? CocoaError(.fileReadUnknown)); return
                    }
                    do {
                        var name = suggestedName ?? url.lastPathComponent
                        if URL(fileURLWithPath: name).pathExtension.isEmpty {
                            name += "." + (UTType(type)?.preferredFilenameExtension ?? url.pathExtension)
                        }
                        try SharedInbox.stage(url, suggestedName: name)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            isDone = true
        } catch { self.error = error.localizedDescription }
    }
}
