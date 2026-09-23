import SwiftUI
import ZeronClient
import ZeronGenerated

/// Agent questions. Tapping options answers; once resolved it collapses to the chosen state.
struct QuestionCard: View {
    let input: MessagePart.Input
    let transcript: Transcript

    @State var picked: [String: Set<String>] = [:]
    @State var typed: [String: String] = [:]

    private var answered: Bool {
        input.resolved || transcript.pending.contains { pending in
            if case .respondInput(let response) = pending.command { return response.requestId == input.requestId }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(input.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question).font(.subheadline)
                    if question.options.isEmpty {
                        TextField("Answer", text: binding(question.id))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        ForEach(question.options, id: \.self) { option in
                            Button { toggle(option, in: question) } label: {
                                Label(option, systemImage: picked[question.id, default: []].contains(option) ? "checkmark.circle.fill" : "circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !answered {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(!complete)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Answer")
            }
        }
        .padding()
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .disabled(answered)
        .opacity(answered ? 0.6 : 1)
    }

    private var complete: Bool {
        input.questions.allSatisfy { question in
            question.options.isEmpty ? !(typed[question.id] ?? "").isEmpty : !picked[question.id, default: []].isEmpty
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }

    private func toggle(_ option: String, in question: UserInputQuestion) {
        var chosen = picked[question.id, default: []]
        if chosen.contains(option) {
            chosen.remove(option)
        } else if question.multiSelect {
            chosen.insert(option)
        } else {
            chosen = [option]
        }
        picked[question.id] = chosen
    }

    private func submit() {
        let answers = input.questions.map { question in
            UserInputAnswer(
                questionId: question.id,
                labels: question.options.isEmpty ? [typed[question.id] ?? ""] : question.options.filter { picked[question.id, default: []].contains($0) }
            )
        }
        transcript.respond(input.requestId, answers: answers)
    }
}
