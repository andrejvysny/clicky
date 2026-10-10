import ClickyCore
import Foundation

let usage = """
clicky-local-bench: local model management and benchmarks (same code as the app).

  models list | download <id> | import <id> <folder> | verify <id> | remove <id> [--yes]   [--models-root path]
  speech --recognizer <id> [--cleanup <id>] [--prompt s1-mini-card-v1|s1-mini-card-v1-lowercase]
         --pipeline asr|asr+cleanup|cleanup-on-reference --dataset disfluency|personal [--manifest path]
         [--split development|held-out] [--ids a,b | --ids-file f | --count N --seed 42] [--warmup 2] [--repetitions 1]
         [--priority foreground-protected|default] [--worker path] [--models-root path] [--out path] [--observation "text"]...
  text   --model <id> --prompt-file f [--max-tokens N] [--warmup N] [--repetitions N] [common options]
  vision --model <id> [--count N] [--seed N] [--warmup N] [--repetitions N] [common options]
"""

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    guard let command = arguments.first else { print(usage); exit(2) }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "models": try await ModelsCommand.run(rest)
    case "speech": try await SpeechCommand.run(rest)
    case "text": try await GenerationCommand.run(vision: false, rest)
    case "vision": try await GenerationCommand.run(vision: true, rest)
    case "--help", "-h", "help": print(usage)
    default: print(usage); exit(2)
    }
} catch let error as CLIError {
    FileHandle.standardError.write(Data("clicky-local-bench: \(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("clicky-local-bench: \(error)\n".utf8))
    exit(1)
}
