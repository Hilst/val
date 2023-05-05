import Core

/// Initializes or assigns storage with a value.
public struct MoveInstruction: Instruction {

  /// The value moved into `target`.
  public let object: Operand

  /// The location to initialize or assign.
  public let target: Operand

  /// The conformance of `target`'s type to `Sinkable` implementing its move operators.
  public let sinkable: Conformance

  /// The site of the code corresponding to that instruction.
  public let site: SourceRange

  /// Creates an instance with the given properties.
  fileprivate init(object: Operand, target: Operand, sinkable: Conformance, site: SourceRange) {
    self.object = object
    self.target = target
    self.sinkable = sinkable
    self.site = site
  }

  public var types: [LoweredType] { [] }

  public var operands: [Operand] { [object, target] }

}

extension Module {

  /// Creates a `move` instruction at `anchor` that moves `object` into `target` using the move
  /// operators defined by `sinkable`.
  ///
  /// This instruction is replaced during IR transformation by either the initialization or
  /// assignment of `target`, depending on its initialization state.
  ///
  /// - Parameters:
  ///   - object: The object to move. Must have an object type.
  ///   - target: The location to initialize or assign. Must have an address type.
  func makeMove(
    _ object: Operand,
    to target: Operand,
    usingConformance sinkable: Conformance,
    anchoredAt anchor: SourceRange
  ) -> MoveInstruction {
    precondition(type(of: object).isObject)
    precondition(type(of: target).isAddress)
    return .init(object: object, target: target, sinkable: sinkable, site: anchor)
  }

}
