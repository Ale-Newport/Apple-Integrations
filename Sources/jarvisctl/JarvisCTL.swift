import Foundation
import JarvisCore
import JarvisIPC

// jarvisctl — talk to the running Jarvis Apple Integrations app over its local Unix socket.

let usage = """
jarvisctl — send commands to Jarvis Apple Integrations (the app must be running).

USAGE
  jarvisctl [options] "Add buy milk to my Shopping reminders list"
  jarvisctl [options] --tool reminders.create --args '{"title":"Buy milk","list":"Shopping"}'
  jarvisctl [options] --confirm TOKEN | --cancel TOKEN | --choose TOKEN INDEX
  jarvisctl [options] --tools | --status | --ping

OPTIONS
  --language en|es     Language of the command and of the reply (default: automatic)
  --session NAME       Scope for "yes / cancel / 2" style replies (default: one per invocation)
  --allow-duplicate    Run even if an identical creation just ran
  --json               Print the raw JSON response
  --socket PATH        Socket path (default: ~/Library/Application Support/JarvisAppleIntegrations/jarvis.sock)
  --timeout SECONDS    Give up after this long (default 120)
  -h, --help           Show this help

EXIT CODES
  0  the request succeeded        1  Jarvis answered but the action did not complete        2  could not reach Jarvis
"""

struct Options {
    var language: String?
    var session: String?
    var allowDuplicate = false
    var json = false
    var socket = JarvisPaths.socketFile().path
    var timeout: TimeInterval = 120
    var request = IPCRequest(type: .command)
    var words: [String] = []
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(for flag: String) -> String {
        guard let next = iterator.next() else { fail("Missing value for \(flag).\n\n\(usage)") }
        return next
    }
    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help": print(usage); exit(0)
        case "--language": options.language = value(for: argument)
        case "--session": options.session = value(for: argument)
        case "--allow-duplicate": options.allowDuplicate = true
        case "--json": options.json = true
        case "--socket": options.socket = value(for: argument)
        case "--timeout": options.timeout = TimeInterval(value(for: argument)) ?? 120
        case "--ping": options.request.type = .ping
        case "--tools": options.request.type = .tools
        case "--status": options.request.type = .status
        case "--tool":
            options.request.type = .tool
            options.request.tool = value(for: argument)
        case "--args":
            let text = value(for: argument)
            guard let object = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)) else { fail("--args must be a JSON object.") }
            options.request.arguments = object
        case "--confirm", "--cancel":
            options.request.type = .resolve
            options.request.token = value(for: argument)
            options.request.decision = argument == "--confirm" ? "confirm" : "cancel"
        case "--choose":
            options.request.type = .resolve
            options.request.token = value(for: argument)
            options.request.decision = "choose"
            guard let index = Int(value(for: argument)) else { fail("--choose needs a numeric INDEX (0-based).") }
            options.request.index = index
        default:
            options.words.append(argument)
        }
    }
    if options.request.type == .command {
        let text = options.words.joined(separator: " ")
        if text.isEmpty { fail(usage) }
        options.request.command = text
    }
    options.request.language = options.language
    options.request.session = options.session ?? "jarvisctl-\(getpid())"
    options.request.allowDuplicate = options.allowDuplicate ? true : nil
    return options
}

func render(_ response: IPCResponse) {
    print(response.message)
    for result in response.results {
        if let confirmation = result.confirmation, let token = confirmation.token {
            print("\nTo proceed:  jarvisctl --confirm \(token)")
            print("To cancel:   jarvisctl --cancel \(token)")
        }
        if let clarification = result.clarification {
            for (index, option) in clarification.options.enumerated() {
                print("  [\(index)] \(option.label)\(option.detail.map { " — \($0)" } ?? "")")
            }
            if let token = clarification.token, !clarification.options.isEmpty { print("\nChoose with:  jarvisctl --choose \(token) INDEX") }
        }
        if let permission = result.permission, let url = permission.settingsURL {
            print("\nGrant access in System Settings: \(url)")
        }
        if let setup = result.setup {
            print("\n\(setup.title)")
            for step in setup.steps { print("  \(step)") }
        }
        for assumption in result.assumptions { print("  (assumed: \(assumption))") }
        for warning in result.warnings { print("  ⚠︎ \(warning)") }
    }
}

@main
struct JarvisCTL {
    static func main() async {
        let options = parse(Array(CommandLine.arguments.dropFirst()))
        let client = IPCClient(socketPath: options.socket, timeout: options.timeout)
        var exitCode: Int32 = 0
        do {
            let response = try await client.send(options.request)
            if options.json {
                FileHandle.standardOutput.write(try IPCCodec.encode(response))
            } else if options.request.type == .tools || options.request.type == .status, let payload = response.data {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: (try? encoder.encode(payload)) ?? Data(), as: UTF8.self))
            } else {
                render(response)
            }
            exitCode = response.success ? 0 : 1
        } catch IPCError.notConnected(let reason) {
            FileHandle.standardError.write(Data("Could not reach Jarvis at \(options.socket): \(reason). Is the app running (and the local control channel enabled in Settings)?\n".utf8))
            exitCode = 2
        } catch IPCError.timedOut {
            FileHandle.standardError.write(Data("Jarvis did not answer within \(Int(options.timeout)) seconds.\n".utf8))
            exitCode = 2
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exitCode = 2
        }
        exit(exitCode)
    }
}
