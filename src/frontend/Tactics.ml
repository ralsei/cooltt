open Basis
open Core
open CodeUnit

module RM = RefineMonad
module T = Tactic
module D = Domain
module S = Syntax
module R = Refiner
module CS = ConcreteSyntax
module Sem = Semantics
module TB = TermBuilder

open Monad.Notation (RM)


let is_total (sign : D.sign) =
  let rec go acc = function
    | D.Field (`User ["fib"],_,D.Clo ([],_)) -> RM.ret @@ acc
    | D.Field (lbl,(D.ElStable (`Ext (0,_,`Global (Cof cof),_)) as tp),sign_clo) ->
      let* cof = RM.lift_cmp @@ Sem.cof_con_to_cof cof in
      RM.abstract (lbl :> Ident.t) tp @@ fun v ->
      let* sign = RM.lift_cmp @@ Sem.inst_sign_clo sign_clo v in
      begin
        RM.lift_cmp @@ Monads.CmpM.test_sequent [] cof |>> function
        | true -> go acc sign
        | false -> go `TotalSome sign
      end
    | D.Field (lbl,tp,sign_clo) ->
      RM.abstract (lbl :> Ident.t) tp @@ fun v ->
      let* sign = RM.lift_cmp @@ Sem.inst_sign_clo sign_clo v in
      go `TotalSome sign
    | D.Empty -> RM.ret `NotTotal
  in
  go `TotalAll sign

let elab_err err =
  let* env = RM.read in
  RM.throw @@ ElabError.ElabError (err, RefineEnv.location env)


let match_goal (tac : _ -> T.Chk.tac RM.m) : T.Chk.tac =
  T.Chk.brule @@
  fun goal ->
  let* tac = tac goal in
  T.Chk.brun tac goal

let rec elim_implicit_connectives : T.Syn.tac -> T.Syn.tac =
  fun tac ->
  T.Syn.rule @@
  let* tm, tp = T.Syn.run @@ T.Syn.whnf tac in
  match tp with
  | D.Sub _ ->
    T.Syn.run @@ elim_implicit_connectives @@ R.Sub.elim @@ T.Syn.rule @@ RM.ret (tm, tp)
  (* The above code only makes sense because I know that the argument to Sub.elim will not be called under a further binder *)
  | D.ElStable _ ->
    T.Syn.run @@ elim_implicit_connectives @@ R.El.elim @@ T.Syn.rule @@ RM.ret (tm, tp)
  | D.Pi (TpPrf _,_,_) -> T.Syn.run @@ elim_implicit_connectives @@ R.Pi.apply (T.Syn.rule @@ RM.ret (tm, tp)) R.Prf.intro
  | _ ->
    RM.ret (tm, tp)

let rec elim_implicit_connectives_and_total : T.Syn.tac -> T.Syn.tac =
  fun tac ->
  T.Syn.rule @@
  let* tm, tp = T.Syn.run @@ T.Syn.whnf tac in
  match tp with
  | D.Sub _ ->
    T.Syn.run @@ elim_implicit_connectives_and_total @@ R.Sub.elim @@ T.Syn.rule @@ RM.ret (tm, tp)
  (* The above code only makes sense because I know that the argument to Sub.elim will not be called under a further binder *)
  | D.ElStable _ ->
    T.Syn.run @@ elim_implicit_connectives_and_total @@ R.El.elim @@ T.Syn.rule @@ RM.ret (tm, tp)
  | D.Pi (TpPrf _,_,_) -> T.Syn.run @@ elim_implicit_connectives @@ R.Pi.apply (T.Syn.rule @@ RM.ret (tm, tp)) R.Prf.intro
  | D.Signature sign ->
    begin
      is_total sign |>> function
      | `TotalAll | `TotalSome -> T.Syn.run @@ elim_implicit_connectives_and_total @@ R.Signature.proj (T.Syn.rule @@ RM.ret (tm,tp)) (`User ["fib"])
      | `NotTotal -> RM.ret (tm,tp)
    end
  | _ ->
    RM.ret (tm, tp)

let rec intro_implicit_connectives : T.Chk.tac -> T.Chk.tac =
  fun tac ->
  T.Chk.whnf @@
  match_goal @@ function
  | D.Sub _, _, _ ->
    RM.ret @@ R.Sub.intro @@ intro_implicit_connectives tac
  | D.ElStable _, _, _ ->
    RM.ret @@ R.El.intro @@ intro_implicit_connectives tac
  | D.Pi (TpPrf _,_,_), _, _  -> RM.ret @@ R.Pi.intro @@ fun _ -> intro_implicit_connectives tac
  | D.Signature sign, _, _ ->
    begin
      is_total sign |>> function
      | `TotalAll -> RM.ret @@ R.Signature.intro (function `User ["fib"] -> Some (intro_implicit_connectives tac) | _ -> None)
      | _ -> RM.ret tac
    end
  | _ ->
    RM.ret tac

let rec intro_subtypes_and_total : T.Chk.tac -> T.Chk.tac =
  fun tac ->
  T.Chk.whnf @@
  match_goal @@ function
  | D.Sub _, _, _ ->
    RM.ret @@ R.Sub.intro @@ intro_subtypes_and_total tac
  | D.Pi (TpPrf _,_,_), _, _  -> RM.ret @@ R.Pi.intro @@ fun _ -> intro_implicit_connectives tac
  | ElStable (`Signature sign_code), _, _ ->
    begin
      RM.lift_cmp @@ Sem.unfold_el (`Signature sign_code) |>> function
      | D.Signature sign ->
        begin
          is_total sign |>> function
          | `TotalAll -> RM.ret @@ R.El.intro @@ R.Signature.intro (function `User ["fib"] -> Some (intro_subtypes_and_total tac) | _ -> None)
          | _ -> RM.ret tac
        end
      | _ -> failwith "impossible"
    end
  | _ ->
    RM.ret tac

let intro_conversions (tac : T.Syn.tac) : T.Chk.tac =
  (* HACK: Because we are using Weak Tarski Universes, we can't just
     use the conversion checker to equate 'tp` and 'univ', as
     'tp' may be 'el code-univ' instead.

     Therefore, we do an explicit check here instead.
     If we add universe levels, this code should probably be reconsidered. *)
  T.Chk.rule ~name:"intro_conversions" @@ function
  | D.Univ | D.ElStable `Univ as tp ->
    let* tm, tp' = T.Syn.run tac in
    let* vtm = RM.lift_ev @@ Sem.eval tm in
    begin
      match tp' with
      | D.Pi (D.ElStable (`Signature vsign) as base, ident, clo) ->
        let* tac' = T.abstract ~ident base @@ fun var ->
          let* fam = RM.lift_cmp @@ Sem.inst_tp_clo clo (T.Var.con var) in
          let* fam = RM.lift_cmp @@ Sem.whnf_tp_ fam in
          (* Same HACK *)
          match fam with
          | D.Univ
          | D.ElStable `Univ -> RM.ret @@ R.Univ.total vsign vtm
          | _ -> RM.ret @@ T.Chk.syn tac
        in
        T.Chk.run tac' tp
      | _ -> T.Chk.run (T.Chk.syn tac) tp
    end
  | tp -> T.Chk.run (T.Chk.syn tac) tp

let rec tac_nary_quantifier (quant : ('a, 'b) R.quantifier) cells body =
  match cells with
  | [] -> body
  | (nm, tac) :: cells ->
    quant tac (nm, fun _ -> tac_nary_quantifier quant cells body)

module Elim =
struct
  type case_tac = CS.pat * T.Chk.tac

  let rec find_case (lbl : string list) (cases : case_tac list) : (CS.pat_arg list * T.Chk.tac) option =
    match cases with
    | (CS.Pat pat, tac) :: _ when pat.lbl = lbl ->
      Some (pat.args, tac)
    | _ :: cases ->
      find_case lbl cases
    | [] ->
      None

  let elim (mot : T.Chk.tac) (cases : case_tac list) (scrut : T.Syn.tac) : T.Syn.tac =
    T.Syn.rule @@
    let* tscrut, ind_tp = T.Syn.run scrut in
    let scrut = T.Syn.rule @@ RM.ret (tscrut, ind_tp) (* only makes sense because because I know 'scrut' won't be used under some binder *) in
    match ind_tp, mot with
    | D.Nat, mot ->
      let* tac_zero : T.Chk.tac =
        match find_case ["zero"] cases with
        | Some ([], tac) -> RM.ret tac
        | Some _ -> elab_err ElabError.MalformedCase
        | None -> RM.ret @@ R.Hole.unleash_hole @@ Some "zero"
      in
      let* tac_suc =
        match find_case ["suc"] cases with
        | Some ([`Simple nm_z], tac) ->
          RM.ret @@ R.Pi.intro ~ident:nm_z @@ fun _ -> R.Pi.intro @@ fun _ -> tac
        | Some ([`Inductive (nm_z, nm_ih)], tac) ->
          RM.ret @@ R.Pi.intro ~ident:nm_z @@ fun _ -> R.Pi.intro ~ident:nm_ih @@ fun _ -> tac
        | Some _ -> elab_err ElabError.MalformedCase
        | None -> RM.ret @@ R.Hole.unleash_hole @@ Some "suc"
      in
      T.Syn.run @@ R.Nat.elim mot tac_zero tac_suc scrut
    | D.Circle, mot ->
      let* tac_base : T.Chk.tac =
        match find_case ["base"] cases with
        | Some ([], tac) -> RM.ret tac
        | Some _ -> elab_err ElabError.MalformedCase
        | None -> RM.ret @@ R.Hole.unleash_hole @@ Some "base"
      in
      let* tac_loop =
        match find_case ["loop"] cases with
        | Some ([`Simple nm_x], tac) ->
          RM.ret @@ R.Pi.intro ~ident:nm_x @@ fun _ -> tac
        | Some _ -> elab_err ElabError.MalformedCase
        | None -> RM.ret @@ R.Hole.unleash_hole @@ Some "loop"
      in
      T.Syn.run @@ R.Circle.elim mot tac_base tac_loop scrut
    | _ ->
      RM.with_pp @@ fun ppenv ->
      let* tp = RM.quote_tp ind_tp in
      elab_err @@ ElabError.CannotEliminate (ppenv, tp)

  let assert_simple_inductive =
    function
    | D.Nat ->
      RM.ret ()
    | D.Circle ->
      RM.ret ()
    | tp ->
      RM.with_pp @@ fun ppenv ->
      let* tp = RM.quote_tp tp in
      elab_err @@ ElabError.ExpectedSimpleInductive (ppenv, tp)

  let lam_elim cases : T.Chk.tac =
    match_goal @@ fun (tp, _, _) ->
    match tp with
    | D.Pi (_, _, fam) ->
      let mot_tac : T.Chk.tac =
        R.Pi.intro @@ fun var -> (* of inductive type *)
        T.Chk.brule @@ fun _goal ->
        let* fib = RM.lift_cmp @@ Sem.inst_tp_clo fam @@ D.ElIn (T.Var.con var) in
        let* tfib = RM.quote_tp fib in
        match tfib with
        | S.El code ->
          RM.ret code
        | _ ->
          RM.expected_connective `El fib
      in
      RM.ret @@
      R.Pi.intro @@ fun x ->
      T.Chk.syn @@
      elim mot_tac cases @@
      R.El.elim @@ T.Var.syn x
    | _ ->
      RM.expected_connective `Pi tp
end

module Equations =
struct

  let step (code_tac : T.Chk.tac) (lhs_tac : T.Chk.tac) (mid_tac : T.Chk.tac) (rhs_tac : T.Chk.tac)
      (p_tac : T.Chk.tac) (q_tac : T.Chk.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Equations.step" @@
    let* code = RM.eval @<< T.Chk.run code_tac D.Univ in
    let* tp = RM.lift_cmp @@ Sem.do_el code in

    let* lhs = RM.eval @<< T.Chk.run lhs_tac tp in
    let* mid = RM.eval @<< T.Chk.run mid_tac tp in
    let* rhs = RM.eval @<< T.Chk.run rhs_tac tp in

    let* p_tp =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.con code @@ fun code ->
      Splice.con lhs @@ fun lhs ->
      Splice.con mid @@ fun mid ->
      Splice.term @@
      TB.el @@ TB.code_path' (TB.lam @@ fun _ -> code) lhs mid
    in
    let* q_tp =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.con code @@ fun code ->
      Splice.con mid @@ fun mid ->
      Splice.con rhs @@ fun rhs ->
      Splice.term @@
      TB.el @@ TB.code_path' (TB.lam @@ fun _ -> code) mid rhs
    in

    let* p = RM.eval @<< T.Chk.run p_tac p_tp in
    let* q = RM.eval @<< T.Chk.run q_tac q_tp in

    let* path_tp =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.con code @@ fun code ->
      Splice.con lhs @@ fun lhs ->
      Splice.con rhs @@ fun rhs ->
      Splice.term @@
      TB.el @@ TB.code_path' (TB.lam @@ fun _ -> code) lhs rhs
    in
    let* path =
      RM.lift_cmp @@
      Sem.splice_tm @@
      Splice.con code @@ fun code ->
      Splice.con p @@ fun p ->
      Splice.con q @@ fun q ->
      Splice.term @@
      TB.el_in @@
      TB.lam @@ fun i ->
      TB.sub_in @@
      TB.hcom code TB.dim0 TB.dim1 (TB.boundary i) @@
      TB.lam @@ fun j ->
      TB.lam @@ fun _ ->
      TB.cof_split [
        TB.join [TB.eq j TB.dim0; TB.eq i TB.dim0], TB.sub_out @@ TB.ap (TB.el_out p) [i];
        TB.eq i TB.dim1, TB.sub_out @@ TB.ap (TB.el_out q) [j]
      ]
    in
    let+ tpath = RM.quote_con path_tp path in
    (tpath, path_tp)

  let qed (code_tac : T.Chk.tac) (x_tac : T.Chk.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Equations.qed" @@
    let* code = RM.eval @<< T.Chk.run code_tac D.Univ in
    let* tp = RM.lift_cmp @@ Sem.do_el code in
    let* x = RM.eval @<< T.Chk.run x_tac tp in
    let* refl_tp =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.con code @@ fun code ->
      Splice.con x @@ fun x ->
      Splice.term @@
      TB.el @@ TB.code_path' (TB.lam @@ fun _ -> code) x x
    in
    let* refl =
      RM.lift_cmp @@
      Sem.splice_tm @@
      Splice.con x @@ fun x ->
      Splice.term @@
      TB.el_in @@
      TB.lam @@ fun _ -> TB.sub_in @@ x
    in
    let+ trefl = RM.quote_con refl_tp refl in
    (trefl, refl_tp)
end
