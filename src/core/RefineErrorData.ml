open Basis

open CodeUnit

module S = Syntax
module D = Domain

module Data =
struct
  type connective =
    [ `Pi
    | `Sg
    | `Telescope
    | `Signature
    | `Nat
    | `Circle
    | `Univ
    | `Dim
    | `Cof
    | `Sub
    | `Prf
    | `LockedPrf
    | `El
    | `ElV
    | `ElHCom
    ]

  type t =
    | UnboundVariable of Ident.t
    | FieldNameMismatches of Ident.user list * Ident.user list
    | ExpectedField of Pp.env * S.sign * S.t * Ident.user
    | ExpectedEqual of Pp.env * S.tp * S.t * S.t * Conversion.Error.t
    | ExpectedEqualTypes of Pp.env * S.tp * S.tp * Conversion.Error.t
    | ExpectedConnective of connective * Pp.env * S.tp
    | ExpectedDimensionLiteral of int
    | ExpectedTrue of Pp.env * S.t
    | VirtualType
    | HoleNotPermitted of Pp.env * S.tp
end
