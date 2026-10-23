import Foundation
import RigPoCKit

@main
struct RigPoC {
    static func main() async {
        initTracing()
        var args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else {
            usage()
        }
        args.removeFirst()

        do {
            switch mode {
            case "--json":
                let result = try await chatJson(
                    system: "Return only compact JSON.",
                    user: "Return {\"ok\":true}",
                    temperature: 0
                )
                print("model=\(result.model) text=\(result.text)")

            case "--embed":
                let texts = args.isEmpty ? ["whole milk", "bananas"] : args
                let vectors = try await embed(texts: texts)
                for (text, vector) in zip(texts, vectors) {
                    let preview = vector.prefix(3).map { String(format: "%.4f", $0) }
                    print("\(text): dims=\(vector.count) first=\(preview)")
                }

            case "--tools":
                let messages = """
                [{"role":"system","content":"Use the provided tool."},
                 {"role":"user","content":"Find the shelf life of whole milk."}]
                """
                let tools = """
                [{"type":"function","function":{
                  "name":"web_search",
                  "description":"Search the web for food storage guidance",
                  "parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}
                }}]
                """
                let result = try await chatWithTools(
                    messagesJson: messages,
                    toolsJson: tools,
                    forceTool: "web_search",
                    temperature: 0
                )
                print("model=\(result.model) content=\(result.content ?? "nil")")
                for call in result.toolCalls {
                    print("tool=\(call.name) id=\(call.id) args=\(call.arguments)")
                }

            case "--tools-loop":
                let messages = """
                [{"role":"system","content":"Use the provided tool."},
                 {"role":"user","content":"Find the shelf life of whole milk."}]
                """
                let tools = """
                [{"type":"function","function":{
                  "name":"web_search",
                  "description":"Search the web for food storage guidance",
                  "parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}
                }}]
                """
                let first = try await chatWithTools(
                    messagesJson: messages,
                    toolsJson: tools,
                    forceTool: "web_search",
                    temperature: 0
                )
                guard let call = first.toolCalls.first else {
                    print("model did not request a tool")
                    return
                }
                let followup: [[String: Any]] = [
                    ["role": "system", "content": "Use the provided tool."],
                    ["role": "user", "content": "Find the shelf life of whole milk."],
                    [
                        "role": "assistant", "content": "",
                        "tool_calls": [[
                            "id": call.id, "type": "function",
                            "function": ["name": call.name, "arguments": call.arguments],
                        ]],
                    ],
                    [
                        "role": "tool", "tool_call_id": call.id,
                        "content": #"{"result":"5-7 days refrigerated after opening"}"#,
                    ],
                ]
                let followupJSON = String(
                    data: try JSONSerialization.data(withJSONObject: followup),
                    encoding: .utf8
                )!
                let final = try await chatWithTools(
                    messagesJson: followupJSON,
                    toolsJson: "[]",
                    forceTool: nil,
                    temperature: 0
                )
                print("tool=\(call.name) args=\(call.arguments)")
                print("final=\(final.content ?? "nil")")
                for call in final.toolCalls {
                    print("follow-up tool=\(call.name) args=\(call.arguments)")
                }

            case "--jev-dynamic":
                let state = #"{"name":"Whole Milk","category":"Dairy"}"#
                let questions = """
                {
                  "perishable": {"type":"noul","instructions":"Is this product perishable?"},
                  "storage": {"type":"choice","instructions":"Where is this stored?",
                    "criteria":{"fridge":"Refrigerated","pantry":"Shelf-stable"}},
                  "days": {"type":"score","instructions":"How many days does it keep?",
                    "criteria":["0 days","1-2 days","3-4 days","5-7 days","8-14 days"]}
                }
                """
                let result = try await jevDynamic(stateJson: state, questionsJson: questions)
                print("model=\(result.model) answers=\(result.answersJson)")

            case "--jev":
                guard let question = args.first else { usage() }
                let state = args.dropFirst().joined(separator: " ")
                let decision = try await jevNoul(question: question, state: state)
                print("question=\(decision.questionId) probability=\(decision.probability) model=\(decision.model)")

            default:
                let prompt = ([mode] + args).joined(separator: " ")
                let reply = try await chat(prompt: prompt)
                print(reply)
            }
            shutdownTracing()
        } catch {
            shutdownTracing()
            fputs("rig error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() -> Never {
        fputs("""
        usage:
          RigPoC <prompt>
          RigPoC --json
          RigPoC --embed [text ...]
          RigPoC --tools
          RigPoC --jev <question> [state]
          RigPoC --jev-dynamic
        """, stderr)
        exit(2)
    }
}
