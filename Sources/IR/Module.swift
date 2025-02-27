import Core
import Foundation
import OrderedCollections
import Utils

/// A module lowered to Val IR.
///
/// An IR module is notionally composed of a collection of functions, one of which may be
/// designated as its entry point (i.e., the `main` function of a Val program).
public struct Module {

  /// The identity of a global defined in a Val IR module.
  public typealias GlobalID = Int

  /// The program defining the functions in `self`.
  public let program: TypedProgram

  /// The module's identifier.
  public let id: ModuleDecl.ID

  /// The def-use chains of the values in this module.
  public private(set) var uses: [Operand: [Use]] = [:]

  /// The globals in the module.
  public private(set) var globals: [any Constant] = []

  /// The functions in the module.
  public private(set) var functions: [Function.ID: Function] = [:]

  /// The synthesized functions used and defined in the module.
  public private(set) var synthesizedDecls = OrderedSet<SynthesizedFunctionDecl>()

  /// The module's entry function, if any.
  public private(set) var entryFunction: Function.ID?

  /// Creates an instance lowering `m` in `p`, reporting errors and warnings to `log`.
  ///
  /// - Requires: `m` is a valid ID in `p`.
  /// - Throws: `Diagnostics` if lowering fails.
  public init(
    lowering m: ModuleDecl.ID, in p: TypedProgram,
    reportingDiagnosticsTo log: inout DiagnosticSet
  ) throws {
    self.program = p
    self.id = m

    Emitter.withInstance(insertingIn: &self, reportingDiagnosticsTo: &log) { (e) in
      e.incorporateTopLevelDeclarations()
    }
    try log.throwOnError()
  }

  /// The module's name.
  public var name: String {
    program.ast[id].baseName
  }

  /// Accesses the given function.
  public subscript(f: Function.ID) -> Function {
    _read { yield functions[f]! }
    _modify { yield &functions[f]! }
  }

  /// Accesses the given block.
  public subscript(b: Block.ID) -> Block {
    _read { yield functions[b.function]!.blocks[b.address] }
    _modify { yield &functions[b.function]![b.address] }
  }

  /// Accesses the given instruction.
  public subscript(i: InstructionID) -> Instruction {
    _read { yield functions[i.function]!.blocks[i.block].instructions[i.address] }
    _modify { yield &functions[i.function]![i.block].instructions[i.address] }
  }

  /// Accesses the instruction denoted by `o` if it is `.register`. Otherwise, returns `nil`.
  public subscript(o: Operand) -> Instruction? {
    if case .register(let i) = o {
      return self[i]
    } else {
      return nil
    }
  }

  /// Returns the type of `operand`.
  public func type(of operand: Operand) -> IR.`Type` {
    switch operand {
    case .register(let instruction):
      return functions[instruction.function]![instruction.block][instruction.address].result!

    case .parameter(let block, let index):
      return functions[block.function]![block.address].inputs[index]

    case .constant(let constant):
      return constant.type
    }
  }

  /// Returns the scope in which `i` is used.
  public func scope(containing i: InstructionID) -> AnyScopeID {
    functions[i.function]![i.block].scope
  }

  /// Returns the IDs of the blocks in `f`.
  ///
  /// The first element of the returned collection is the function's entry; other elements are in
  /// no particular order.
  public func blocks(
    in f: Function.ID
  ) -> LazyMapSequence<Function.Blocks.Indices, Block.ID> {
    self[f].blocks.indices.lazy.map({ .init(f, $0.address) })
  }

  /// Returns the IDs of the instructions in `b`, in order.
  public func instructions(
    in b: Block.ID
  ) -> LazyMapSequence<Block.Instructions.Indices, InstructionID> {
    self[b].instructions.indices.lazy.map({ .init(b.function, b.address, $0.address) })
  }

  /// Returns the ID the instruction before `i`.
  func instruction(before i: InstructionID) -> InstructionID? {
    functions[i.function]![i.block].instructions.address(before: i.address)
      .map({ InstructionID(i.function, i.block, $0) })
  }

  /// Returns the ID the instruction after `i`.
  func instruction(after i: InstructionID) -> InstructionID? {
    functions[i.function]![i.block].instructions.address(after: i.address)
      .map({ InstructionID(i.function, i.block, $0) })
  }

  /// Returns the global identity of `block`'s terminator, if it exists.
  func terminator(of block: Block.ID) -> InstructionID? {
    if let a = functions[block.function]!.blocks[block.address].instructions.lastAddress {
      return InstructionID(block, a)
    } else {
      return nil
    }
  }

  /// Returns the register asssigned by `i`, if any.
  func result(of i: InstructionID) -> Operand? {
    if self[i].result != nil {
      return .register(i)
    } else {
      return nil
    }
  }

  /// Returns whether the IR in `self` is well-formed.
  ///
  /// Use this method as a sanity check to verify the module's invariants.
  public func isWellFormed() -> Bool {
    for f in functions.keys {
      if !isWellFormed(function: f) { return false }
    }
    return true
  }

  /// Returns whether `f` is well-formed.
  ///
  /// Use this method as a sanity check to verify the function's invariants.
  public func isWellFormed(function f: Function.ID) -> Bool {
    return true
  }

  /// Applies `p` to in this module, which is in `ir`.
  public mutating func applyPass(_ p: ModulePass, in ir: IR.Program) {
    switch p {
    case .depolymorphize:
      depolymorphize(in: ir)
    }
  }

  /// Applies all mandatory passes in this module, accumulating diagnostics in `log` and throwing
  /// if a pass reports an error.
  public mutating func applyMandatoryPasses(
    reportingDiagnosticsTo log: inout DiagnosticSet
  ) throws {
    func run(_ pass: (Function.ID) -> Void) throws {
      for (k, f) in functions where f.entry != nil {
        pass(k)
      }
      try log.throwOnError()
    }

    try run({ removeDeadCode(in: $0, diagnostics: &log) })
    try run({ reifyAccesses(in: $0, diagnostics: &log) })
    try run({ closeBorrows(in: $0, diagnostics: &log) })
    try run({ normalizeObjectStates(in: $0, diagnostics: &log) })
    try run({ ensureExclusivity(in: $0, diagnostics: &log) })

    try generateSyntheticImplementations(reportingDiagnosticsTo: &log)
  }

  /// Inserts the IR for the synthesized declarations defined in this module, reporting diagnostics
  /// to `log` and throwing if a an error occurred.
  mutating func generateSyntheticImplementations(
    reportingDiagnosticsTo log: inout DiagnosticSet
  ) throws {
    Emitter.withInstance(insertingIn: &self, reportingDiagnosticsTo: &log) { (e) in
      e.incorporateSyntheticDeclarations()
    }
    try log.throwOnError()
  }

  /// Adds a global constant and returns its identity.
  mutating func addGlobal<C: Constant>(_ value: C) -> GlobalID {
    let id = globals.count
    globals.append(value)
    return id
  }

  /// Assigns `identity` to `function` in `self`.
  ///
  /// - Requires: `identity` is not already assigned.
  mutating func addFunction(_ function: Function, for identity: Function.ID) {
    precondition(functions[identity] == nil)
    functions[identity] = function
  }

  /// Returns the identity of the Val IR function corresponding to `d`.
  mutating func demandFunctionDeclaration(lowering d: FunctionDecl.ID) -> Function.ID {
    let f = Function.ID(d)
    if functions[f] != nil { return f }

    let parameters = program.accumulatedGenericParameters(of: d)
    let output = program.relations.canonical((program[d].type.base as! CallableType).output)
    let inputs = loweredParameters(of: d)

    let entity = Function(
      isSubscript: false,
      site: program.ast[d].site,
      linkage: .external,
      genericParameters: Array(parameters),
      inputs: inputs,
      output: output,
      blocks: [])
    addFunction(entity, for: f)

    // Determine if the new function is the module's entry.
    if program.isModuleEntry(d) {
      assert(entryFunction == nil)
      entryFunction = f
    }

    return f
  }

  /// Returns the identity of the Val IR function corresponding to `d`.
  mutating func demandSubscriptDeclaration(lowering d: SubscriptImpl.ID) -> Function.ID {
    let f = Function.ID(d)
    if functions[f] != nil { return f }

    let parameters = program.accumulatedGenericParameters(of: d)
    let output = program.relations.canonical(SubscriptImplType(program[d].type)!.output)
    let inputs = loweredParameters(of: d)

    let entity = Function(
      isSubscript: true,
      site: program.ast[d].site,
      linkage: .external,
      genericParameters: Array(parameters),
      inputs: inputs,
      output: output,
      blocks: [])

    addFunction(entity, for: f)
    return f
  }

  /// Returns the identifier of the Val IR initializer corresponding to `d`.
  mutating func demandInitializerDeclaration(lowering d: InitializerDecl.ID) -> Function.ID {
    precondition(!program.ast[d].isMemberwise)

    let f = Function.ID(initializer: d)
    if functions[f] != nil { return f }

    let parameters = program.accumulatedGenericParameters(of: d)
    let inputs = loweredParameters(of: d)

    let entity = Function(
      isSubscript: false,
      site: program.ast[d].introducer.site,
      linkage: .external,
      genericParameters: Array(parameters),
      inputs: inputs,
      output: .void,
      blocks: [])

    addFunction(entity, for: f)
    return f
  }

  /// Returns the identity of the Val IR function implementing the deinitializer defined in
  /// conformance `c`.
  mutating func demandDeinitDeclaration(from c: Core.Conformance) -> Function.ID {
    let d = program.ast.deinitRequirement()
    switch c.implementations[d]! {
    case .concrete:
      fatalError("not implemented")

    case .synthetic(let s):
      return demandSyntheticDeclaration(lowering: s)
    }
  }

  /// Returns the identity of the Val IR function implementing the `k` variant move-operator
  /// defined in conformance `c`.
  ///
  /// - Requires: `k` is either `.set` or `.inout`
  mutating func demandMoveOperatorDeclaration(
    _ k: AccessEffect, from c: Core.Conformance
  ) -> Function.ID {
    let d = program.ast.moveRequirement(k)
    switch c.implementations[d]! {
    case .concrete:
      fatalError("not implemented")

    case .synthetic(let s):
      return demandSyntheticDeclaration(lowering: s)
    }
  }

  /// Returns the identity of the Val IR function corresponding to `d`.
  mutating func demandSyntheticDeclaration(lowering d: SynthesizedFunctionDecl) -> Function.ID {
    let f = Function.ID(d)
    if functions[f] != nil { return f }

    let output = program.relations.canonical(d.type.output)
    var inputs: [Parameter] = []
    appendCaptures(d.type.captures, passed: d.type.receiverEffect, to: &inputs)
    appendParameters(d.type.inputs, to: &inputs)

    let entity = Function(
      isSubscript: false,
      site: .empty(at: program.ast[id].site.first()),
      linkage: .external,
      genericParameters: [],  // TODO
      inputs: inputs,
      output: output,
      blocks: [])

    // Determine if the new function is defined in this module.
    if program.module(containing: d.scope) == id {
      synthesizedDecls.append(d)
    }

    addFunction(entity, for: f)
    return f
  }

  /// Returns the lowered declarations of `d`'s parameters.
  private func loweredParameters(of d: FunctionDecl.ID) -> [Parameter] {
    let captures = LambdaType(program[d].type)!.captures.lazy.map { (e) in
      program.relations.canonical(e.type)
    }
    var result: [Parameter] = zip(program.captures(of: d), captures).map({ (c, e) in
      .init(c, capturedAs: e)
    })
    result.append(contentsOf: program.ast[d].parameters.map(pairedWithLoweredType(parameter:)))
    return result
  }

  /// Returns the lowered declarations of `d`'s parameters.
  ///
  /// `d`'s receiver comes first and is followed by `d`'s formal parameters, from left to right.
  private func loweredParameters(of d: InitializerDecl.ID) -> [Parameter] {
    var result: [Parameter] = []
    result.append(pairedWithLoweredType(parameter: program.ast[d].receiver))
    result.append(contentsOf: program.ast[d].parameters.map(pairedWithLoweredType(parameter:)))
    return result
  }

  /// Returns the lowered declarations of `d`'s parameters.
  private func loweredParameters(of d: SubscriptImpl.ID) -> [Parameter] {
    let captures = SubscriptImplType(program[d].type)!.captures.lazy.map { (e) in
      program.relations.canonical(e.type)
    }
    var result: [Parameter] = zip(program.captures(of: d), captures).map({ (c, e) in
      .init(c, capturedAs: e)
    })

    let bundle = SubscriptDecl.ID(program[d].scope)!
    if let p = program.ast[bundle].parameters {
      result.append(contentsOf: p.map(pairedWithLoweredType(parameter:)))
    }

    return result
  }

  /// Returns `d`, which declares a parameter, paired with its lowered type.
  private func pairedWithLoweredType(parameter d: ParameterDecl.ID) -> Parameter {
    let t = program.relations.canonical(program[d].type)
    return .init(decl: AnyDeclID(d), type: ParameterType(t)!)
  }

  /// Appends to `inputs` the parameters corresponding to the given `captures` passed `effect`.
  private func appendCaptures(
    _ captures: [TupleType.Element], passed effect: AccessEffect, to inputs: inout [Parameter]
  ) {
    inputs.reserveCapacity(captures.count)
    for c in captures {
      switch program.relations.canonical(c.type).base {
      case let p as RemoteType:
        precondition(p.access != .yielded, "cannot lower yielded parameter")
        inputs.append(.init(decl: nil, type: ParameterType(p)))
      case let p:
        precondition(effect != .yielded, "cannot lower yielded parameter")
        inputs.append(.init(decl: nil, type: ParameterType(effect, ^p)))
      }
    }
  }

  /// Appends `parameters` to `inputs`, ensuring that their types are canonical.
  private func appendParameters(
    _ parameters: [CallableTypeParameter], to inputs: inout [Parameter]
  ) {
    inputs.reserveCapacity(parameters.count)
    for p in parameters {
      let t = ParameterType(program.relations.canonical(p.type))!
      precondition(t.access != .yielded, "cannot lower yielded parameter")
      inputs.append(.init(decl: nil, type: t))
    }
  }

  /// Returns a map from `f`'s generic arguments to their skolemized form.
  ///
  /// - Requires: `f` is declared in `self`.
  public func parameterization(in f: Function.ID) -> GenericArguments {
    var result = GenericArguments()
    for p in functions[f]!.genericParameters {
      guard
        let t = MetatypeType(program[p].type),
        let u = GenericTypeParameterType(t.instance)
      else {
        // TODO: Handle value parameters
        fatalError("not implemented")
      }

      result[p] = ^SkolemType(quantifying: u)
    }
    return result
  }

  /// Returns the entry of `f`.
  ///
  /// - Requires: `f` is declared in `self`.
  public func entry(of f: Function.ID) -> Block.ID? {
    functions[f]!.entry.map({ Block.ID(f, $0) })
  }

  /// Appends to `f` an entry block that is in `scope`, returning its identifier.
  ///
  /// - Requires: `f` is declared in `self` and doesn't have an entry block.
  @discardableResult
  mutating func appendEntry<T: ScopeID>(in scope: T, to f: Function.ID) -> Block.ID {
    let ir = functions[f]!
    assert(ir.blocks.isEmpty)

    // In functions, the last parameter of the entry denotes the function's return value.
    var parameters = ir.inputs.map({ IR.`Type`.address($0.type.bareType) })
    if !ir.isSubscript {
      parameters.append(.address(ir.output))
    }

    return appendBlock(in: scope, taking: parameters, to: f)
  }

  /// Appends to `f` a basic block that is in `scope` and accepts `parameters` to `f`, returning
  /// its identifier.
  ///
  /// - Requires: `f` is declared in `self`.
  @discardableResult
  mutating func appendBlock<T: ScopeID>(
    in scope: T,
    taking parameters: [IR.`Type`] = [],
    to f: Function.ID
  ) -> Block.ID {
    let a = functions[f]!.appendBlock(in: scope, taking: parameters)
    return Block.ID(f, a)
  }

  /// Removes `block` and updates def-use chains.
  ///
  /// - Requires: No instruction in `block` is used by an instruction outside of `block`.
  @discardableResult
  mutating func removeBlock(_ block: Block.ID) -> Block {
    for i in instructions(in: block) {
      precondition(allUses(of: i).allSatisfy({ $0.user.block == block.address }))
      removeUsesMadeBy(i)
    }
    return functions[block.function]!.removeBlock(block.address)
  }

  /// Swaps `old` by `new`.
  ///
  /// `old` is removed and the def-use chains are updated so that the uses made by `old` are
  /// replaced by the uses made by `new` and all uses of `old` refer to `new`. After the call,
  /// `self[old] == new`.
  ///
  /// - Requires: `new` produces results with the same types as `old`.
  mutating func replace<I: Instruction>(_ old: InstructionID, with new: I) {
    precondition(self[old].result == new.result)
    removeUsesMadeBy(old)
    _ = insert(new) { (m, i) in
      m[old] = i
      return old
    }
  }

  /// Swaps all uses of `old` in `f` by `new` and updates the def-use chains.
  ///
  /// - Requires: `new` as the same type as `old`. `f` is in `self`.
  mutating func replaceUses(of old: Operand, with new: Operand, in f: Function.ID) {
    precondition(old != new)
    precondition(type(of: old) == type(of: new))

    guard var oldUses = uses[old], !oldUses.isEmpty else { return }
    var newUses = uses[new] ?? []

    var end = oldUses.count
    for i in oldUses.indices.reversed() where oldUses[i].user.function == f {
      let u = oldUses[i]
      self[u.user].replaceOperand(at: u.index, with: new)
      newUses.append(u)
      end -= 1
      oldUses.swapAt(i, end)
    }
    oldUses.removeSubrange(end...)

    uses[old] = oldUses
    uses[new] = newUses
  }

  /// Inserts `newInstruction` at `boundary` and returns its identity.
  @discardableResult
  mutating func insert(
    _ newInstruction: Instruction, at boundary: InsertionPoint
  ) -> InstructionID {
    switch boundary {
    case .start(let b):
      return prepend(newInstruction, to: b)
    case .end(let b):
      return append(newInstruction, to: b)
    case .before(let i):
      return insert(newInstruction, before: i)
    case .after(let i):
      return insert(newInstruction, after: i)
    }
  }

  /// Adds `newInstruction` at the start of `block` and returns its identity.
  @discardableResult
  mutating func prepend(_ newInstruction: Instruction, to block: Block.ID) -> InstructionID {
    precondition(!(newInstruction is Terminator), "terminator must appear last in a block")
    return insert(newInstruction) { (m, i) in
      InstructionID(block, m[block].instructions.prepend(newInstruction))
    }
  }

  /// Adds `newInstruction` at the end of `block` and returns its identity.
  @discardableResult
  mutating func append(_ newInstruction: Instruction, to block: Block.ID) -> InstructionID {
    precondition(!(self[block].instructions.last is Terminator), "insertion after terminator")
    return insert(newInstruction) { (m, i) in
      InstructionID(block, m[block].instructions.append(newInstruction))
    }
  }

  /// Inserts `newInstruction` at `position` and returns its identity.
  ///
  /// The instruction is inserted before the instruction currently at `position`. You can pass a
  /// "past the end" position to append at the end of a block.
  @discardableResult
  mutating func insert(
    _ newInstruction: Instruction, at position: InstructionIndex
  ) -> InstructionID {
    precondition(!(newInstruction is Terminator), "terminator must appear last in a block")
    return insert(newInstruction) { (m, i) in
      let address = m.functions[position.function]![position.block].instructions
        .insert(newInstruction, at: position.index)
      return InstructionID(position.function, position.block, address)
    }
  }

  /// Inserts `newInstruction` before `successor` and returns its identity.
  @discardableResult
  mutating func insert(
    _ newInstruction: Instruction, before successor: InstructionID
  ) -> InstructionID {
    precondition(!(newInstruction is Terminator), "terminator must appear last in a block")
    return insert(newInstruction) { (m, i) in
      let address = m.functions[successor.function]![successor.block].instructions
        .insert(newInstruction, before: successor.address)
      return InstructionID(successor.function, successor.block, address)
    }
  }

  /// Inserts `newInstruction` after `predecessor` and returns its identity.
  @discardableResult
  mutating func insert(
    _ newInstruction: Instruction, after predecessor: InstructionID
  ) -> InstructionID {
    precondition(!(instruction(after: predecessor) is Terminator), "insertion after terminator")
    return insert(newInstruction) { (m, i) in
      let address = m.functions[predecessor.function]![predecessor.block].instructions
        .insert(newInstruction, after: predecessor.address)
      return InstructionID(predecessor.function, predecessor.block, address)
    }
  }

  /// Inserts `newInstruction` with `impl` and returns its identity.
  private mutating func insert(
    _ newInstruction: Instruction, with impl: (inout Self, Instruction) -> InstructionID
  ) -> InstructionID {
    // Insert the instruction.
    let user = impl(&self, newInstruction)

    // Update the def-use chains.
    for i in 0 ..< newInstruction.operands.count {
      uses[newInstruction.operands[i], default: []].append(Use(user: user, index: i))
    }

    return user
  }

  /// Removes instruction `i` and updates def-use chains.
  ///
  /// - Requires: The result of `i` have no users.
  mutating func removeInstruction(_ i: InstructionID) {
    precondition(result(of: i).map(default: true, { uses[$0, default: []].isEmpty }))
    removeUsesMadeBy(i)
    self[i.function][i.block].instructions.remove(at: i.address)
  }

  /// Removes all instructions after `i` in its containing block and updates def-use chains.
  ///
  /// - Requires: Let `S` be the set of removed instructions, all users of a result of `j` in `S`
  ///   are also in `S`.
  mutating func removeAllInstructionsAfter(_ i: InstructionID) {
    while let a = self[i.function][i.block].instructions.lastAddress, a != i.address {
      removeInstruction(.init(i.function, i.block, a))
    }
  }

  /// Returns the uses of all the registers assigned by `i`.
  private func allUses(of i: InstructionID) -> [Use] {
    result(of: i).map(default: [], { uses[$0, default: []] })
  }

  /// Removes `i` from the def-use chains of its operands.
  private mutating func removeUsesMadeBy(_ i: InstructionID) {
    for o in self[i].operands {
      uses[o]?.removeAll(where: { $0.user == i })
    }
  }

  /// Returns the operands from which the address denoted by `a` derives.
  ///
  /// The (static) provenances of an address denote the original operands from which it derives.
  /// They form a set because an address computed by a projection depends on that projection's
  /// arguments and because an address defined as a parameter of a basic block with multiple
  /// predecessors depends on that bock's arguments.
  func provenances(_ a: Operand) -> Set<Operand> {
    // TODO: Block arguments
    guard let i = a.instruction else { return [a] }

    switch self[i] {
    case let s as AdvancedByBytes:
      return provenances(s.base)
    case let s as Access:
      return provenances(s.source)
    case let s as Project:
      return s.operands.reduce(
        into: [],
        { (p, o) in
          if type(of: o).isAddress { p.formUnion(provenances(o)) }
        })
    case let s as SubfieldView:
      return provenances(s.recordAddress)
    case let s as WrapExistentialAddr:
      return provenances(s.witness)
    default:
      return [a]
    }
  }

  /// Returns `true` if `o` is sink in `f`.
  ///
  /// - Requires: `o` is defined in `f`.
  func isSink(_ o: Operand, in f: Function.ID) -> Bool {
    let e = entry(of: f)!
    return provenances(o).allSatisfy { (p) -> Bool in
      switch p {
      case .parameter(e, let i):
        return self.functions[f]!.inputs[i].type.access == .sink

      case .register(let i):
        switch self[i] {
        case let s as ProjectBundle:
          return s.capabilities.contains(.sink)
        case let s as Project:
          return s.projection.access == .sink
        default:
          return true
        }

      default:
        return true
      }
    }
  }

}
