import SwiftUI
import ZeronClient

struct ContentView: View {
    @State var connection = Connection()

    var body: some View {
        Text(String(describing: connection.status))
    }
}
