import SwiftUI

@main
struct SmartCardHostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

private struct ContentView: View {
    @State private var status = "Checking…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WSurf Smart Card")
                .font(.headline)
            Text("This app carries the smart card token extension. Keep it in /Applications; it needs no further interaction.")
                .foregroundStyle(.secondary)
            Text(status)
                .font(.callout)
        }
        .padding(20)
        .frame(width: 420)
        .task { status = await Self.extensionStatus() }
    }

    private static func extensionStatus() async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            process.arguments = ["-m", "-p", "com.apple.ctk-tokens"]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return "Token extension status unavailable." }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return output.contains("io.wsagency.smartcard.ctk")
                ? "Token extension registered. Enable it in System Settings › Login Items & Extensions if cards are not offered."
                : "Token extension not registered yet."
        }.value
    }
}
