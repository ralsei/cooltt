open Basis

module Make (Symbol : Symbol.S) =
struct
  module Cof = Kado.Syntax.Endo

  type t =
    | Var of int
    | Global of Symbol.t
    | Let of t * Ident.t * t
    | Ann of t * tp

    | Zero
    | Suc of t
    | NatElim of t * t * t * t

    | Base
    | Loop of t
    | CircleElim of t * t * t * t

    | Lam of Ident.t * t
    | Ap of t * t

    | Pair of t * t
    | Fst of t
    | Snd of t

    | Struct of (Ident.user * t) list
    | Proj of t * Ident.user

    | Coe of t * t * t * t
    | HCom of t * t * t * t * t
    | Com of t * t * t * t * t

    | SubIn of t
    | SubOut of t

    | Dim0
    | Dim1
    | Cof of (t, t) Cof.t
    | ForallCof of t
    | CofSplit of (t * t) list
    | Prf

    | ElIn of t
    | ElOut of t

    | Box of t * t * t * t * t
    | Cap of t * t * t * t * t

    | VIn of t * t * t * t
    | VProj of t * t * t * t * t

    | CodeExt of int * t * [`Global of t] * t
    | CodePi of t * t
    | CodeSg of t * t
    | CodeSignature of (Ident.user * t) list
    | CodeNat
    | CodeUniv
    | CodeV of t * t * t * t
    | CodeCircle

    | ESub of sub * t
    (** Explicit substition *)

  and tp =
    | Univ
    | El of t
    | TpVar of int
    | TpDim
    | TpCof
    | TpPrf of t
    | TpCofSplit of (t * tp) list
    | Sub of tp * t * t
    | Pi of tp * Ident.t * tp
    | Sg of tp * Ident.t * tp
    | Signature of sign
    | Nat
    | Circle
    | TpESub of sub * tp

  and sign = (Ident.user * tp) list

  (** The language of substitions from {{:https://arxiv.org/abs/1102.2405} Abel, Coquand, and Pagano}. *)
  and sub =
    | SbI
    (** The identity substitution [Γ → Γ]. *)

    | SbC of sub * sub
    (** The composition of substitutions [δ ∘ γ]. *)

    | Sb1
    (** The terminal substitution [Γ → 1]. *)

    | SbE of sub * t
    (** The universal substitution into an extended context [<γ, a>]. *)

    | SbP
    (** The projection from a extended context [Γ.A → Γ]. *)

  module CofBuilder = Kado.Builder.Endo.Make
      (struct
        type dim = t
        type cof = t
        let dim0 = Dim0
        let dim1 = Dim1
        let equal_dim = (=)
        let cof phi = Cof phi
        let uncof = function Cof phi -> Some phi | _ -> None
      end)
end
