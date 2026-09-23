import SwiftUI
import ZeronClient

/// First run: where is the host, and what token opens it.
struct ConnectView: View {
    @Environment(AppModel.self) var app
    @State var address = ""
    @State var token = ""

    private var endpoint: Endpoint? { Endpoint(address: address, token: token) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("host:port", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $token)
                        .submitLabel(.go)
                        .onSubmit(connect)
                } footer: {
                    Text("Zeron > Settings > Mobile")
                }
            }
            .navigationTitle("Zeron")
            .toolbar {
                Button(action: connect) {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .disabled(endpoint == nil)
                .accessibilityLabel("Connect")
            }
        }
    }

    private func connect() {
        if let endpoint {
            app.connect(endpoint)
        }
    }
}
