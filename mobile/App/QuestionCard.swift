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
                    Text(question.question).font(.subheadline).foregroundStyle(Theme.text)
                    if question.options.isEmpty {
                        TextField("Answer", text: binding(question.id))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .panel(Theme.raised)
                    } else {
                        ForEach(question.options, id: \.self) { option in
                            let chosen = picked[question.id, default: []].contains(option)
                            Button { toggle(option, in: question) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: chosen ? "checkmark.circle.fill" : "checkmark.circle")
                                        .foregroundStyle(chosen ? Theme.accent : Theme.faint)
                                    Text(option).foregroundStyle(Theme.text)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .panel(chosen ? Theme.accent.opacity(0.12) : Theme.raised)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !answered {
                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline)
                        .foregroundStyle(complete ? Theme.bg : Theme.faint)
                        .circleControl(complete ? Theme.text : Theme.raised)
                }
                .disabled(!complete)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Answer")
            }
        }
        .padding(12)
        .panel()
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
