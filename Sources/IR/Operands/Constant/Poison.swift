/// A poison value in Val IR.
public struct Poison: Constant, Hashable {

  /// The type of the poison.
  public let type: IR.`Type`

}

extension Poison: CustomStringConvertible {

  public var description: String { "poison" }

}
