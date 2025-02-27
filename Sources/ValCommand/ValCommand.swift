import ArgumentParser
import CodeGenLLVM
import Core
import Foundation
import FrontEnd
import IR
import LLVM
import Utils
import ValModule

public struct ValCommand: ParsableCommand {

  /// The type of the output files to generate.
  private enum OutputType: String, ExpressibleByArgument {

    /// AST before type-checking.
    case rawAST = "raw-ast"

    /// Val IR before mandatory transformations.
    case rawIR = "raw-ir"

    /// Val IR.
    case ir = "ir"

    /// LLVM IR
    case llvm = "llvm"

    /// Executable binary.
    case binary = "binary"
  }

  public static let configuration = CommandConfiguration(commandName: "valc")

  @Flag(
    name: [.customLong("modules")],
    help: "Compile inputs as separate modules.")
  private var compileInputAsModules: Bool = false

  @Flag(
    name: [.customLong("import-builtin")],
    help: "Import the built-in module.")
  private var importBuiltinModule: Bool = false

  @Flag(
    name: [.customLong("no-std")],
    help: "Do not include the standard library.")
  private var noStandardLibrary: Bool = false

  @Flag(
    name: [.customLong("typecheck")],
    help: "Type-check the input file(s).")
  private var typeCheckOnly: Bool = false

  @Option(
    name: [.customLong("trace-inference")],
    help: ArgumentHelp(
      "Enable tracing of type inference requests at the given line.",
      valueName: "file:line"))
  private var inferenceTracingSite: SourceLine?

  @Option(
    name: [.customLong("emit")],
    help: ArgumentHelp(
      "Emit the specified type output files. From: raw-ast, raw-ir, ir, llvm, binary",
      valueName: "output-type"))
  private var outputType: OutputType = .binary

  @Option(
    name: [.customLong("transform")],
    help: ArgumentHelp(
      "Apply the specify transformations after IR lowering.",
      valueName: "transforms"))
  private var transforms: ModulePassList?

  @Option(
    name: [.customShort("L")],
    help: ArgumentHelp(
      "Add a directory to the library search path.",
      valueName: "directory"))
  private var librarySearchPaths: [String] = []

  @Option(
    name: [.customShort("l")],
    help: ArgumentHelp(
      "Link the generated crate(s) to the specified native library.",
      valueName: "name"))
  private var libraries: [String] = []

  @Option(
    name: [.customShort("o")],
    help: ArgumentHelp("Write output to <file>.", valueName: "file"),
    transform: URL.init(fileURLWithPath:))
  private var outputURL: URL?

  @Flag(
    name: [.short, .long],
    help: "Use verbose output.")
  private var verbose: Bool = false

  @Flag(
    name: [.customShort("O")],
    help: "Compile with optimizations.")
  private var optimize: Bool = false

  @Argument(
    transform: URL.init(fileURLWithPath:))
  private var inputs: [URL]

  public init() {}

  /// The URL of the current working directory.
  private var currentDirectory: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }

  public func run() throws {
    let (exitCode, diagnostics) = try execute()

    diagnostics.render(
      into: &standardError, style: ProcessInfo.ansiTerminalIsConnected ? .styled : .unstyled)

    ValCommand.exit(withError: exitCode)
  }

  /// Executes the command, returning its exit status and any generated diagnostics.
  ///
  /// Propagates any thrown errors that are not Val diagnostics,
  public func execute() throws -> (ExitCode, DiagnosticSet) {
    var diagnostics = DiagnosticSet()
    do {
      try executeCommand(diagnostics: &diagnostics)
    } catch let d as DiagnosticSet {
      assert(d.containsError, "Diagnostics containing no errors were thrown")
      return (ExitCode.failure, diagnostics)
    }
    return (ExitCode.success, diagnostics)
  }

  /// Executes the command, accumulating diagnostics in `diagnostics`.
  private func executeCommand(diagnostics: inout DiagnosticSet) throws {

    if compileInputAsModules {
      fatalError("compilation as modules not yet implemented.")
    }

    let productName = makeProductName(inputs)
    var ast = noStandardLibrary ? AST.coreModule : AST.standardLibrary

    // The module whose Val files were given on the command-line
    let sourceModule = try ast.makeModule(
      productName, sourceCode: sourceFiles(in: inputs),
      builtinModuleAccess: importBuiltinModule, diagnostics: &diagnostics)

    if outputType == .rawAST {
      try write(ast, to: astFile(productName))
      return
    }

    let program = try TypedProgram(
      ast, tracingInferenceIn: inferenceTracingSite, diagnostics: &diagnostics)
    if typeCheckOnly { return }

    // IR

    var ir = try lower(program: program, reportingDiagnosticsTo: &diagnostics)

    if outputType == .ir || outputType == .rawIR {
      let m = ir.modules[sourceModule]!
      try m.description.write(to: irFile(productName), atomically: true, encoding: .utf8)
      return
    }

    // LLVM

    ir.applyPass(.depolymorphize)

    let target = try LLVM.TargetMachine(for: .host(), relocation: .pic)
    var llvmProgram = try LLVMProgram(ir, mainModule: sourceModule, for: target)

    if optimize {
      llvmProgram.optimize()
    } else {
      llvmProgram.applyMandatoryPasses()
    }

    if outputType == .llvm {
      let m = llvmProgram.llvmModules[sourceModule]!
      try m.description.write(to: llvmFile(productName), atomically: true, encoding: .utf8)
      return
    }

    // Executables

    assert(outputType == .binary)

    let objectDir = try FileManager.default.makeTemporaryDirectory()
    let objectFiles = try llvmProgram.write(.objectFile, to: objectDir)
    let binaryPath = executableOutputPath(default: productName)

    #if os(macOS)
      try makeMacOSExecutable(at: binaryPath, linking: objectFiles, diagnostics: &diagnostics)
    #elseif os(Linux)
      try makeLinuxExecutable(at: binaryPath, linking: objectFiles, diagnostics: &diagnostics)
    #else
      _ = objectFiles
      _ = binaryPath
      fatalError("not implemented")
    #endif
  }

  /// Returns `program` lowered to Val IR, accumulating diagnostics in `log` and throwing if an
  /// error occured.
  ///
  /// Mandatory IR passes are applied unless `self.outputType` is `.rawIR`.
  private func lower(
    program: TypedProgram, reportingDiagnosticsTo log: inout DiagnosticSet
  ) throws -> IR.Program {
    var loweredModules: [ModuleDecl.ID: IR.Module] = [:]
    for d in program.ast.modules {
      loweredModules[d] = try lower(d, in: program, reportingDiagnosticsTo: &log)
    }

    var ir = IR.Program(syntax: program, modules: loweredModules)
    if let t = transforms {
      for p in t.elements { ir.applyPass(p) }
    }
    return ir
  }

  /// Returns `m`, which is `program`, lowered to Val IR, accumulating diagnostics in `log` and
  /// throwing if an error occured.
  ///
  /// Mandatory IR passes are applied unless `self.outputType` is `.rawIR`.
  private func lower(
    _ m: ModuleDecl.ID, in program: TypedProgram, reportingDiagnosticsTo log: inout DiagnosticSet
  ) throws -> IR.Module {
    var ir = try IR.Module(lowering: m, in: program, reportingDiagnosticsTo: &log)
    if outputType != .rawIR {
      try ir.applyMandatoryPasses(reportingDiagnosticsTo: &log)
    }
    return ir
  }

  /// Combines the object files located at `objects` into an executable file at `binaryPath`,
  private func makeMacOSExecutable(
    at binaryPath: String, linking objects: [URL], diagnostics: inout DiagnosticSet
  ) throws {
    let xcrun = try find("xcrun")
    let sdk =
      try runCommandLine(xcrun, ["--sdk", "macosx", "--show-sdk-path"], diagnostics: &diagnostics)
      ?? ""

    var arguments = [
      "-r", "ld", "-o", binaryPath,
      "-L\(sdk)/usr/lib",
    ]
    arguments.append(contentsOf: librarySearchPaths.map({ "-L\($0)" }))
    arguments.append(contentsOf: objects.map(\.path))
    arguments.append("-lSystem")
    arguments.append("-lc++")
    arguments.append(contentsOf: libraries.map({ "-l\($0)" }))

    try runCommandLine(xcrun, arguments, diagnostics: &diagnostics)
  }

  /// Combines the object files located at `objects` into an executable file at `binaryPath`,
  /// logging diagnostics to `log`.
  private func makeLinuxExecutable(
    at binaryPath: String,
    linking objects: [URL],
    diagnostics: inout DiagnosticSet
  ) throws {
    var arguments = [
      "-o", binaryPath,
    ]
    arguments.append(contentsOf: librarySearchPaths.map({ "-L\($0)" }))
    arguments.append(contentsOf: objects.map(\.path))
    arguments.append(contentsOf: libraries.map({ "-l\($0)" }))

    // Note: We use "clang" rather than "ld" so that to deal with the entry point of the program.
    // See https://stackoverflow.com/questions/51677440
    try runCommandLine(find("clang++"), arguments, diagnostics: &diagnostics)
  }

  /// Returns `self.outputURL` transformed as a suitable executable file path, using `productName`
  /// as a default name if `outputURL` is `nil`.
  ///
  /// The returned path has a `.exe` extension on Windows.
  private func executableOutputPath(default productName: String) -> String {
    var binaryPath = outputURL?.path ?? URL(fileURLWithPath: productName).path
    #if os(Windows)
      if !binaryPath.hasSuffix(".exe") { binaryPath += ".exe" }
    #endif
    return binaryPath
  }

  /// If `inputs` contains a single URL `u` whose path is non-empty, returns the last component of
  /// `u` without any path extension and stripping all leading dots. Otherwise, returns "Main".
  private func makeProductName(_ inputs: [URL]) -> String {
    if let u = inputs.uniqueElement {
      let n = u.deletingPathExtension().lastPathComponent.drop(while: { $0 == "." })
      if !n.isEmpty { return String(n) }
    }
    return "Main"
  }

  /// Writes `source` to `url`, possibly with verbose logging.
  private func write(_ source: String, toURL url: URL) throws {
    if verbose {
      standardError.write("Writing \(url)")
    }
    try source.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Creates a module from the contents at `url` and adds it to the AST.
  ///
  /// - Requires: `url` must denote a directly.
  private func addModule(url: URL) {
    fatalError("not implemented")
  }

  /// Returns the path of the specified executable.
  private func find(_ executable: String) throws -> String {
    if let path = ValCommand.executableLocationCache[executable] { return path }

    // Search in the current working directory.
    var candidate = currentDirectory.appendingPathComponent(executable)
    if FileManager.default.fileExists(atPath: candidate.path) {
      ValCommand.executableLocationCache[executable] = candidate.path
      return candidate.path
    }

    // Search in the PATH.
    #if os(Windows)
      let environment = ProcessInfo.processInfo.environment["Path"] ?? ""
      for root in environment.split(separator: ";") {
        candidate = URL(fileURLWithPath: String(root)).appendingPathComponent(executable)
        if FileManager.default.fileExists(atPath: candidate.path + ".exe") {
          ValCommand.executableLocationCache[executable] = candidate.path
          return candidate.path
        }
      }
    #else
      let environment = ProcessInfo.processInfo.environment["PATH"] ?? ""
      for root in environment.split(separator: ":") {
        candidate = URL(fileURLWithPath: String(root)).appendingPathComponent(executable)
        if FileManager.default.fileExists(atPath: candidate.path) {
          ValCommand.executableLocationCache[executable] = candidate.path
          return candidate.path
        }
      }
    #endif

    throw EnvironmentError("executable not found: \(executable)")
  }

  /// Executes the program at `path` with the specified arguments in a subprocess.
  @discardableResult
  private func runCommandLine(
    _ programPath: String,
    _ arguments: [String] = [],
    diagnostics: inout DiagnosticSet
  ) throws -> String? {
    if verbose {
      standardError.write(([programPath] + arguments).joined(separator: " "))
    }

    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: programPath)
    process.arguments = arguments
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8).flatMap({ (result) -> String? in
      let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    })
  }

  /// A map from executable name to path of the named binary.
  private static var executableLocationCache: [String: String] = [:]

  /// Writes a textual descriptioni of `input` to the given `output` file.
  func write(_ input: AST, to output: URL) throws {
    let encoder = JSONEncoder().forAST
    try encoder.encode(input).write(to: output, options: .atomic)
  }

  /// Given the desired name of the compiler's product, returns the file to write when "raw-ast" is
  /// selected as the output type.
  private func astFile(_ productName: String) -> URL {
    outputURL ?? URL(fileURLWithPath: productName + ".ast.json")
  }

  /// Given the desired name of the compiler's product, returns the file to write when "ir" or
  /// "raw-ir" is selected as the output type.
  private func irFile(_ productName: String) -> URL {
    outputURL ?? URL(fileURLWithPath: productName + ".vir")
  }

  /// Given the desired name of the compiler's product, returns the file to write when "llvm" is
  /// selected as the output type.
  private func llvmFile(_ productName: String) -> URL {
    outputURL ?? URL(fileURLWithPath: productName + ".ll")
  }

  /// Given the desired name of the compiler's product, returns the file to write when "binary" is
  /// selected as the output type.
  private func binaryFile(_ productName: String) -> URL {
    outputURL ?? URL(fileURLWithPath: productName)
  }

}
