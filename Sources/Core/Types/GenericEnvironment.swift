import Utils

/// An object that provides context to interpret the generic parameters of a declaration.
public struct GenericEnvironment {

  /// The generic parameters introduced in the environment, in the order there declaration appears
  /// in Val sources.
  public let parameters: [GenericParameterDecl.ID]

  /// The uninstantiated type constraints.
  public private(set) var constraints: [GenericConstraint] = []

  /// A table from types to their entry.
  private var ledger: [AnyType: Int] = [:]

  /// The equivalence classes and their associated conformance sets.
  private var entries: [(equivalences: Set<AnyType>, conformances: Set<TraitType>)] = []

  /// Creates an environment that introduces `parameters` in a declaration space.
  public init(introducing parameters: [GenericParameterDecl.ID]) {
    self.parameters = parameters
  }

  /// Returns the set of traits to which `type` conforms in the environment.
  public func conformedTraits(of type: AnyType) -> Set<TraitType> {
    if let i = ledger[type] {
      return entries[i].conformances
    } else {
      return []
    }
  }

  /// Inserts constraint `c` to the environment, updating equivalence classes.
  public mutating func insertConstraint(_ c: GenericConstraint) {
    constraints.append(c)
    switch c.value {
    case .equality(let lhs, let rhs):
      registerEquivalence(lhs, rhs)
    case .conformance(let lhs, let rhs):
      registerConformance(lhs, to: rhs)
    default:
      break
    }
  }

  private mutating func registerEquivalence(_ l: AnyType, _ r: AnyType) {
    if let i = ledger[l] {
      // `l` is part of a class.
      if let j = ledger[r] {
        // `r` is part of a class too; merge the entries.
        entries[i].equivalences.formUnion(entries[j].equivalences)
        entries[i].conformances.formUnion(entries[j].conformances)
        entries[j] = ([], [])
      } else {
        // `r` isn't part of a class.
        entries[i].equivalences.insert(r)
      }

      // Update the ledger for `r`.
      ledger[r] = i
    } else if let j = ledger[r] {
      // `l` isn't part of a class, but `r` is.
      ledger[l] = j
      entries[j].equivalences.insert(l)
    } else {
      // Neither `l` nor `r` are part of a class.
      ledger[l] = entries.count
      ledger[l] = entries.count
      entries.append((equivalences: [l, r], conformances: []))
    }
  }

  private mutating func registerConformance(_ l: AnyType, to traits: Set<TraitType>) {
    if let i = ledger[l] {
      // `l` is part of a class.
      entries[i].conformances.formUnion(traits)
    } else {
      // `l` isn't part of a class.
      ledger[l] = entries.count
      entries.append((equivalences: [l], conformances: traits))
    }
  }

}
