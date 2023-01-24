import Core

/// A C++ integer literal expression.
struct CXXBooleanLiteralExpr: CXXExpr {

  /// The value of the literal.
  let value: Bool

  /// The original node in Val AST.
  let original: BooleanLiteralExpr.Typed?

  func precedence() -> Int {
    0
  }
  func isLeftToRight() -> Bool {
    true  // doesn't really matter
  }

}
