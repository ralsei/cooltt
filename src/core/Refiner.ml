open Containers

open Basis
open Monads
open Bwd

open CodeUnit

module D = Domain
module S = Syntax
module Env = RefineEnv
module Err = RefineError
module RM = RefineMonad
module RMU = Monad.Util (RM)
module T = Tactic
module Splice = Splice
module TB = TermBuilder
module Sem = Semantics
module Qu = Quote

open Monad.Notation (RM)
module MU = Monad.Util (RM)

exception CJHM


type ('a, 'b) quantifier = 'a -> Ident.t * (T.var -> 'b) -> 'b

type 'a telescope =
  | Bind of Ident.user * 'a * (T.var -> 'a telescope)
  | Done

module GlobalUtil : sig
  val destruct_cells : Env.cell list -> (Ident.t * S.tp) list m
  val multi_pi : Env.cell list -> S.tp m -> S.tp m
  val multi_ap : Env.cell bwd -> D.cut -> D.cut
end =
struct
  let rec destruct_cells =
    function
    | [] -> RM.ret []
    | cell :: cells ->
      let ctp, _ = Env.Cell.contents cell in
      let ident = Env.Cell.ident cell in
      let+ base = RM.quote_tp ctp
      and+ rest = RM.abstract ident ctp @@ fun _ -> destruct_cells cells in
      (ident, base) :: rest

  let rec multi_pi (cells : Env.cell list) (finally : S.tp m) : S.tp m =
    match cells with
    | [] -> finally
    | cell :: cells ->
      let ctp, _ = Env.Cell.contents cell in
      let ident = Env.Cell.ident cell in
      let+ base = RM.quote_tp ctp
      and+ fam = RM.abstract ident ctp @@ fun _ -> multi_pi cells finally in
      S.Pi (base, ident, fam)

  let rec multi_ap (cells : Env.cell bwd) (finally : D.cut) : D.cut =
    match cells with
    | Emp -> finally
    | Snoc (cells, cell) ->
      let tp, con = Env.Cell.contents cell in
      multi_ap cells finally |> D.push @@ D.KAp (tp, con)
end


module Probe : sig
  val probe_chk : string option -> T.Chk.tac -> T.Chk.tac
  val probe_boundary : T.Chk.tac -> T.Chk.tac -> T.Chk.tac
  val probe_syn : string option -> T.Syn.tac -> T.Syn.tac
end =
struct
  let print_state lbl tp : unit m =
    let* env = RM.read in
    let cells = Env.locals env in

    RM.globally @@
    let* ctx = GlobalUtil.destruct_cells @@ BwdLabels.to_list cells in
    () |> RM.emit (RefineEnv.location env) @@ fun fmt () ->
    Format.fprintf fmt "Emitted hole:@,  @[<v>%a@]@." (S.pp_sequent ~lbl ctx) tp

  let boundary_satisfied tm tp phi clo : _ m =
    let* con = RM.lift_ev @@ Sem.eval tm in
    let+ res = RM.trap @@ RM.abstract Ident.anon (D.TpPrf phi) @@ fun prf ->
      RM.equate tp con @<< RM.lift_cmp @@ Sem.inst_tm_clo clo prf
    in match res with
    | Ok _ -> `BdrySat
    | Error _ -> `BdryUnsat

  let print_boundary tm tp phi clo : unit m =
    let* env = RM.read in
    let cells = Env.locals env in
    let* bdry_sat = boundary_satisfied tm tp phi clo in
    let* stp = RM.quote_tp @@ D.Sub (tp, phi, clo) in

    RM.globally @@
    let* ctx = GlobalUtil.destruct_cells @@ BwdLabels.to_list cells in
    () |> RM.emit (RefineEnv.location env) @@ fun fmt () ->
    Format.fprintf fmt "Emitted hole:@,  @[<v>%a@]@." (S.pp_partial_sequent bdry_sat ctx) (tm, stp)

  let probe_chk name tac =
    T.Chk.brule ~name:"probe_chk" @@ fun (tp, phi, clo) ->
    let* s = T.Chk.brun tac (tp, phi, clo) in
    let+ () =
      let* stp = RM.quote_tp @@ D.Sub (tp, phi, clo) in
      print_state name stp
    in
    s

  let probe_boundary probe tac =
    T.Chk.brule ~name:"probe_boundary" @@ fun (tp, phi, clo) ->
    let* probe_tm = T.Chk.run probe tp in
    let* () = print_boundary probe_tm tp phi clo in
    T.Chk.brun tac (tp, phi, clo)

  let probe_syn name tac =
    T.Syn.rule ~name:"probe_syn" @@
    let* s, tp = T.Syn.run tac in
    let+ () =
      let* stp = RM.quote_tp tp in
      print_state name stp
    in
    s, tp
end


module Hole : sig
  val silent_hole : string option -> T.Chk.tac
  val unleash_hole : string option -> T.Chk.tac
  val silent_syn_hole : string option -> T.Syn.tac
  val unleash_syn_hole : string option -> T.Syn.tac
end =
struct
  let assert_hole_possible tp =
    RM.lift_cmp @@ Sem.whnf_tp_ tp |>>
    function
    | D.TpDim | D.TpCof | D.TpPrf _ ->
      let* ttp = RM.quote_tp tp in
      RM.with_pp @@ fun ppenv ->
      RM.refine_err @@ Err.HoleNotPermitted (ppenv, ttp)
    | _ -> RM.ret ()

  let make_hole name (tp, phi, clo) : D.cut m =
    let* () = assert_hole_possible tp in
    let* env = RM.read in
    let cells = Env.locals env in

    RM.globally @@
    let* sym =
      let* tp = GlobalUtil.multi_pi (BwdLabels.to_list cells) @@ RM.quote_tp @@ D.Sub (tp, phi, clo) in
      let* vtp = RM.lift_ev @@ Sem.eval_tp tp in
      let ident =
        match name with
        | None -> Ident.anon
        | Some str -> Ident.machine @@ "?" ^ str
      in
      RM.add_global ~unfolder:None ~shadowing:true ident vtp
    in

    let* () = RM.inc_num_holes in

    let cut = GlobalUtil.multi_ap cells (D.Global sym, []) in
    RM.ret (D.UnstableCut (cut, D.KSubOut (phi, clo)), [])

  let silent_hole name : T.Chk.tac =
    T.Chk.brule ~name:"silent_hole" @@ fun (tp, phi, clo) ->
    let* cut = make_hole name (tp, phi, clo) in
    RM.quote_cut cut

  let unleash_hole name : T.Chk.tac =
    Probe.probe_chk name @@
    T.Chk.brule ~name:"unleash_hole" @@ fun (tp, phi, clo) ->
    let* cut = make_hole name (tp, phi, clo) in
    RM.quote_cut cut

  let silent_syn_hole name : T.Syn.tac =
    T.Syn.rule ~name:"silent_syn_hole" @@
    let* cut = make_hole name @@ (D.Univ, CofBuilder.bot, D.Clo (S.tm_abort, {tpenv = Emp; conenv = Emp})) in
    let tp = D.ElCut cut in
    let+ tm = tp |> T.Chk.run @@ unleash_hole name in
    tm, tp

  let unleash_syn_hole name : T.Syn.tac =
    Probe.probe_syn name @@
    T.Syn.rule ~name:"unleash_syn_hole" @@
    let* cut = make_hole name @@ (D.Univ, CofBuilder.bot, D.Clo (S.tm_abort, {tpenv = Emp; conenv = Emp})) in
    let tp = D.ElCut cut in
    let+ tm = tp |> T.Chk.run @@ unleash_hole name in
    tm, tp
end


module Sub =
struct
  let formation (tac_base : T.Tp.tac) (tac_phi : T.Chk.tac) (tac_tm : T.var -> T.Chk.tac) : T.Tp.tac =
    T.Tp.rule ~name:"Sub.formation" @@
    let* base = T.Tp.run tac_base in
    let* vbase = RM.lift_ev @@ Sem.eval_tp base in
    let* phi = T.Chk.run tac_phi D.TpCof in
    let+ tm =
      let* vphi = RM.lift_ev @@ Sem.eval_cof phi in
      T.abstract (D.TpPrf vphi) @@ fun prf ->
      vbase |> T.Chk.run @@ tac_tm prf
    in
    S.Sub (base, phi, tm)

  let intro (tac : T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"Sub.intro" @@
    function
    | D.Sub (tp_a, phi_a, clo_a), phi_sub, clo_sub ->
      let phi = CofBuilder.join [phi_a; phi_sub] in
      let* partial =
        RM.lift_cmp @@ Sem.splice_tm @@
        Splice.cof phi_a @@ fun phi_a ->
        Splice.cof phi_sub @@ fun phi_sub ->
        Splice.clo clo_a @@ fun fn_a ->
        Splice.clo clo_sub @@ fun fn_sub ->
        Splice.term @@ TB.lam @@ fun _ ->
        TB.cof_split
          [phi_a, TB.ap fn_a [TB.prf];
           phi_sub, TB.sub_out @@ TB.ap fn_sub [TB.prf]]
      in
      let+ tm = T.Chk.brun tac (tp_a, phi, D.un_lam partial) in
      S.SubIn tm
    | tp, _, _ ->
      RM.expected_connective `Sub tp

  let elim (tac : T.Syn.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Sub.elim" @@
    let* tm, subtp = T.Syn.run tac in
    match subtp with
    | D.Sub (tp, _, _) ->
      RM.ret (S.SubOut tm, tp)
    | tp ->
      RM.expected_connective `Sub tp
end

module Dim =
struct
  let formation : T.Tp.tac =
    T.Tp.virtual_rule ~name:"Dim.formation" @@
    RM.ret S.TpDim

  let dim0 : T.Chk.tac =
    T.Chk.rule ~name:"Dim.dim0" @@
    function
    | D.TpDim ->
      RM.ret S.Dim0
    | tp ->
      RM.expected_connective `Dim tp

  let dim1 : T.Chk.tac =
    T.Chk.rule ~name:"Dim.dim1" @@
    function
    | D.TpDim ->
      RM.ret S.Dim1
    | tp ->
      RM.expected_connective `Dim tp

  let literal : int -> T.Chk.tac =
    function
    | 0 -> dim0
    | 1 -> dim1
    | n ->
      T.Chk.rule ~name:"Dim.literal" @@ fun _ ->
      RM.refine_err @@ Err.ExpectedDimensionLiteral n
end

module Cof =
struct
  let formation : T.Tp.tac =
    T.Tp.virtual_rule ~name:"Cof.formation" @@
    RM.ret S.TpCof

  let expected_cof =
    RM.expected_connective `Cof

  let eq tac0 tac1 =
    T.Chk.rule ~name:"Cof.eq" @@
    function
    | D.TpCof ->
      let+ r0 = T.Chk.run tac0 D.TpDim
      and+ r1 = T.Chk.run tac1 D.TpDim in
      S.CofBuilder.eq r0 r1
    | tp ->
      expected_cof tp

  let le tac0 tac1 =
    T.Chk.rule ~name:"Cof.le" @@
    function
    | D.TpCof ->
      let+ r0 = T.Chk.run tac0 D.TpDim
      and+ r1 = T.Chk.run tac1 D.TpDim in
      S.CofBuilder.le r0 r1
    | tp ->
      expected_cof tp


  let join tacs =
    T.Chk.rule ~name:"Cof.join" @@
    function
    | D.TpCof ->
      let+ phis = MU.map (fun t -> T.Chk.run t D.TpCof) tacs in
      S.CofBuilder.join phis
    | tp ->
      expected_cof tp

  let meet tacs =
    T.Chk.rule ~name:"Cof.meet" @@
    function
    | D.TpCof ->
      let+ phis = MU.map (fun t -> T.Chk.run t D.TpCof) tacs in
      S.CofBuilder.meet phis
    | tp ->
      expected_cof tp

  let boundary tac = join [eq tac Dim.dim0; eq tac Dim.dim1]

  let assert_true vphi =
    RM.lift_cmp @@ CmpM.test_sequent [] vphi |>> function
    | true -> RM.ret ()
    | false ->
      RM.with_pp @@ fun ppenv ->
      let* tphi = RM.quote_cof vphi in
      RM.refine_err @@ Err.ExpectedTrue (ppenv, tphi)


  module Split : sig
    type branch_tac = {cof : T.Chk.tac; bdy : T.var -> T.Chk.tac}
    val split : branch_tac list -> T.Chk.tac
  end =
  struct
    type branch_tac = {cof : T.Chk.tac; bdy : T.var -> T.Chk.tac}
    type branch_tac' = {cof : D.cof; tcof : S.t; bdy : T.var -> T.Chk.tac}
    type branch = {cof : D.cof; tcof : S.t; fn : D.con; bdy : S.t}

    let rec gather_branches (branches : branch_tac list) : (D.cof * branch_tac' list) m =
      match branches with
      | [] -> RM.ret (CofBuilder.bot, [])
      | branch :: branches ->
        let* tphi = T.Chk.run branch.cof D.TpCof in
        let* vphi = RM.lift_ev @@ Sem.eval_cof tphi in
        let+ psi, tacs = gather_branches branches in
        CofBuilder.join [vphi; psi], {cof = vphi; tcof = tphi; bdy = branch.bdy} :: tacs


    let splice_split branches =
      let phis, fns = List.split branches in
      RM.lift_cmp @@ Sem.splice_tm @@
      Splice.cons (List.map D.cof_to_con phis) @@ fun phis ->
      Splice.cons fns @@ fun fns ->
      Splice.term @@ TB.lam @@ fun _ ->
      TB.cof_split @@ List.combine phis @@ List.map (fun fn -> TB.ap fn [TB.prf]) fns

    module State =
    struct
      open BwdNotation
      type t =
        {disj : D.cof;
         fns : (D.cof * D.con) bwd;
         acc : (S.t * S.t) bwd}

      let init : t =
        {disj = CofBuilder.bot;
         fns = Emp;
         acc = Emp}

      let append : t -> branch -> t =
        fun state branch ->
        {disj = CofBuilder.join [state.disj; branch.cof];
         fns = state.fns #< (branch.cof, branch.fn);
         acc = state.acc #< (branch.tcof, branch.bdy)}
    end

    let split (branches : branch_tac list) : T.Chk.tac =
      T.Chk.brule ~name:"Split.split" @@ fun (tp, psi, psi_clo) ->
      let* disjunction, tacs = gather_branches branches in
      let* () = assert_true disjunction in

      let step : State.t -> branch_tac' -> State.t m =
        fun state branch ->
          let* bdy =
            let psi' = CofBuilder.join [state.disj; psi] in
            let* psi'_fn = splice_split @@ (psi, D.Lam (Ident.anon, psi_clo)) :: BwdLabels.to_list state.fns in
            T.abstract (D.TpPrf branch.cof) @@ fun prf ->
            T.Chk.brun (branch.bdy prf) (tp, psi', D.un_lam psi'_fn)
          in
          let+ fn = RM.lift_ev @@ Sem.eval (S.Lam (Ident.anon, bdy)) in
          State.append state {cof = branch.cof; tcof = branch.tcof; fn; bdy}
      in

      let rec fold : State.t -> branch_tac' list -> S.t m =
        fun state ->
          function
          | [] ->
            RM.ret @@ S.CofSplit (BwdLabels.to_list state.acc)
          | tac :: tacs ->
            let* state = step state tac in
            fold state tacs
      in

      fold State.init tacs
  end

  include Split

end

module Prf =
struct
  let formation tac_phi =
    T.Tp.virtual_rule ~name:"Prf.formation" @@
    let+ phi = T.Chk.run tac_phi D.TpCof in
    S.TpPrf phi

  let intro =
    T.Chk.brule ~name:"Prf.intro" @@
    function
    | D.TpPrf phi, _, _ ->
      let+ () = Cof.assert_true phi in
      S.Prf
    | tp, _, _ ->
      RM.expected_connective `Prf tp
end

module Pi =
struct
  let formation : (T.Tp.tac, T.Tp.tac) quantifier =
    fun tac_base (nm, tac_fam) ->
      T.Tp.rule ~name:"Pi.formation" @@
      let* base = T.Tp.run_virtual tac_base in
      let* vbase = RM.lift_ev @@ Sem.eval_tp base in
      let+ fam = T.abstract ~ident:nm vbase @@ fun var -> T.Tp.run @@ tac_fam var in
      S.Pi (base, nm, fam)

  let intro ?(ident = Ident.anon) (tac_body : T.var -> T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"Pi.intro" @@
    function
    | D.Pi (base, _, fam), phi, phi_clo ->
      T.abstract ~ident base @@ fun var ->
      let* fib = RM.lift_cmp @@ Sem.inst_tp_clo fam @@ T.Var.con var in
      let+ tm = T.Chk.brun (tac_body var) (fib, phi, D.un_lam @@ D.compose (D.Lam (Ident.anon, D.apply_to (T.Var.con var))) @@ D.Lam (Ident.anon, phi_clo)) in
      S.Lam (ident, tm)
    | tp, _, _ ->
      RM.expected_connective `Pi tp

  let apply tac_fun tac_arg : T.Syn.tac =
    T.Syn.rule ~name:"Pi.apply" @@
    let* tfun, tp = T.Syn.run tac_fun in
    match tp with
    | D.Pi (base, _, fam) ->
      let* targ = T.Chk.run tac_arg base in
      let+ fib =
        let* varg = RM.lift_ev @@ Sem.eval targ in
        RM.lift_cmp @@ Sem.inst_tp_clo fam varg
      in
      S.Ap (tfun, targ), fib
    | _ ->
      Format.printf "Bad apply!! %a@." D.pp_tp tp;
      RM.expected_connective `Pi tp
end

module Sg =
struct
  let formation : (T.Tp.tac, T.Tp.tac) quantifier =
    fun tac_base (nm, tac_fam) ->
      T.Tp.rule ~name:"Sg.formation" @@
      let* base = T.Tp.run tac_base in
      let* vbase = RM.lift_ev @@ Sem.eval_tp base in
      let+ fam = T.abstract ~ident:nm vbase @@ fun var -> T.Tp.run @@ tac_fam var in
      S.Sg (base, nm, fam)

  let intro (tac_fst : T.Chk.tac) (tac_snd : T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"Sg.intro" @@
    function
    | D.Sg (base, _, fam), phi, phi_clo ->
      let* tfst = T.Chk.brun tac_fst (base, phi, D.un_lam @@ D.compose D.fst @@ D.Lam (Ident.anon, phi_clo)) in
      let+ tsnd =
        let* vfst = RM.lift_ev @@ Sem.eval tfst in
        let* fib = RM.lift_cmp @@ Sem.inst_tp_clo fam vfst in
        T.Chk.brun tac_snd (fib, phi, D.un_lam @@ D.compose D.snd @@ D.Lam (Ident.anon, phi_clo))
      in
      S.Pair (tfst, tsnd)
    | tp , _, _ ->
      RM.expected_connective `Sg tp

  let pi1 tac : T.Syn.tac =
    T.Syn.rule ~name:"Sg.pi1" @@
    let* tpair, tp = T.Syn.run tac in
    match tp with
    | D.Sg (base, _, _) ->
      RM.ret (S.Fst tpair, base)
    | _ ->
      RM.expected_connective `Sg tp


  let pi2 tac : T.Syn.tac =
    T.Syn.rule ~name:"Sg.pi2" @@
    let* tpair, tp = T.Syn.run tac in
    match tp with
    | D.Sg (_, _, fam) ->
      let+ fib =
        let* vfst = RM.lift_ev @@ Sem.eval @@ S.Fst tpair in
        RM.lift_cmp @@ Sem.inst_tp_clo fam vfst
      in
      S.Snd tpair, fib
    | _ ->
      RM.expected_connective `Sg tp
end

module Univ =
struct
  let formation : T.Tp.tac =
    T.Tp.rule ~name:"Univ.formation" @@
    RM.ret S.Univ

  let univ_tac : string -> (D.tp -> S.t RM.m) -> T.Chk.tac =
    fun nm m ->
    T.Chk.rule ~name:nm @@
    function
    | D.Univ -> m D.Univ
    | tp ->
      RM.expected_connective `Univ tp

  let univ : T.Chk.tac =
    univ_tac "Univ.univ" @@ fun _ ->
    RM.ret S.CodeUniv


  let nat : T.Chk.tac =
    univ_tac "Univ.nat" @@ fun _ -> RM.ret S.CodeNat

  let circle : T.Chk.tac =
    univ_tac "Univ.circle" @@ fun _ -> RM.ret S.CodeCircle

  let quantifier (tac_base : T.Chk.tac) (tac_fam : T.Chk.tac) =
    fun univ ->
    let* base = T.Chk.run tac_base univ in
    let* vbase = RM.lift_ev @@ Sem.eval base in
    let* famtp =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.con vbase @@ fun base ->
      Splice.tp univ @@ fun univ ->
      Splice.term @@ TB.pi (TB.el base) @@ fun _ -> univ
    in
    let+ fam = T.Chk.run tac_fam famtp in
    base, fam

  let quantifiers (mk_fields : ('a Ident.some * (D.tp -> S.t m)) list) (univ : D.tp) : ('a Ident.some * S.t) list m =
    let (idents, ks) = List.split mk_fields in
    let rec mk_fams fams vfams =
      function
      | [] -> RM.ret fams
      | k :: ks ->
        let* famtp =
          RM.lift_cmp @@
          Sem.splice_tp @@
          Splice.tp univ @@ fun univ ->
          Splice.cons vfams @@ fun args -> Splice.term @@ TB.pis ~idents:(idents :> Ident.t list) args @@ fun _ -> univ
        in
        let* fam = k famtp in
        let* vfam = RM.lift_ev @@ Sem.eval fam in
        mk_fams (fams @ [fam]) (vfams @ [vfam]) ks
    in
    let+ fams = mk_fams [] [] ks in
    List.combine idents fams

  let quote_sign_codes (vsign : (Ident.user * D.con) list) (univ : D.tp) : (Ident.user * S.t) list m =
    quantifiers (List.map (fun (lbl, vcode) -> (lbl, fun tp -> RM.quote_con tp vcode)) vsign) univ

  let pi tac_base tac_fam : T.Chk.tac =
    univ_tac "Univ.pi" @@ fun univ ->
    let+ tp, fam = quantifier tac_base tac_fam univ in
    S.CodePi (tp, fam)

  let sg tac_base tac_fam : T.Chk.tac =
    univ_tac "Univ.sg" @@ fun univ ->
    let+ tp, fam = quantifier tac_base tac_fam univ in
    S.CodeSg (tp, fam)

  (* [NOTE: Sig Code Quantifiers]
     When we are creating a code for a signature, we need to make sure
     that we can depend on the values of previous fields. To achieve this,
     we do something similar to pi/sigma codes, and add in extra pi types to
     bind the names of previous fields. As an example, the signature:
         sig (x : type)
             (y : (arg : x) -> type)
             (z : (arg1 : x) -> (arg2 : y) -> type)
     will produce the following goals:
          type
          (x : type) -> type
          (x : type) -> (y : type) -> type
     and once the tactics for each field are run, we will get the following
     signature code (notice the lambdas!):
         sig (x : type)
             (y : x => (arg : x) -> type)
             (z : x => y => (arg1 : x) -> (arg2 : y) -> type)
  *)
  let signature (tacs : (Ident.user * T.Chk.tac) list) : T.Chk.tac =
    univ_tac "Univ.signature" @@ fun univ ->
    let+ fields = quantifiers (List.map (fun (lbl, tac) -> (lbl, T.Chk.run tac)) tacs) univ in
    S.CodeSignature fields

  (* [NOTE: Patch Quantifiers]
     As described in [NOTE: Sig Code Quantifiers], the field types of a signature code
     all use lambdas to bind variables from earlier on in the signature. Therefore,
     when we construct the patched versions of the field codes, we need to re-insert
     the lambdas.

     However, the situation is made more complicated by the fact that we only patching
     _some_ of the values of the signature type. This means that we can't just naively
     apply the field code to all the previous patch values, as their may not be any patch values
     for some fields!

     This requires us to run each of the patch tactics at pi types, which then causes
     the patches to be lambdas. This means that we need to do some fancier application
     when we construct the final codes. Most notably, we need to make sure to properly
     eliminate the 'ext' types introduced by previous patches.
  *)
  let patch_fields (sign : (Ident.user * D.con) list) (tacs : Ident.user -> T.Chk.tac option) (univ : D.tp) : S.t m =
    let rec go (field_names : Ident.user list) (codes : D.con list) (elim_conns : (S.t TB.m -> S.t TB.m) list) sign =
      match sign with
      | (field_name, vfield_tp) :: sign ->
        let* (code, elim_conn) =
          match tacs field_name with
          | Some tac ->
            let* patch_tp =
              RM.lift_cmp @@
              Sem.splice_tp @@
              Splice.con vfield_tp @@ fun field_tp ->
              Splice.cons codes @@ fun codes -> Splice.term @@ TB.pis ~idents:(field_names :> Ident.t list) codes @@ fun args -> TB.el @@ TB.ap field_tp @@ ListUtil.zip_with (@@) elim_conns args
            in
            let* patch = T.Chk.run tac patch_tp in
            let* vpatch = RM.lift_ev @@ Sem.eval patch in
            let+ ext_code =
              RM.lift_cmp @@
              Sem.splice_tm @@
              Splice.con vfield_tp @@ fun field_tp ->
              Splice.con vpatch @@ fun patch ->
              Splice.term @@ TB.lams (field_names :> Ident.t list) @@ fun args -> TB.code_ext 0 (TB.ap field_tp @@ ListUtil.zip_with (@@) elim_conns args) TB.top @@ TB.lam @@ fun _ -> TB.ap patch args
            in
            (ext_code, fun arg -> TB.sub_out @@ TB.el_out arg)
          | None ->
            let+ code =
              RM.lift_cmp @@
              Sem.splice_tm @@
              Splice.con vfield_tp @@ fun field_tp ->
              Splice.term @@ TB.lams (field_names :> Ident.t list) @@ fun args -> TB.ap field_tp @@ ListUtil.zip_with (@@) elim_conns args
            in
            (code, Fun.id)
        in
        go (field_names @ [field_name]) (codes @ [code]) (elim_conns @ [elim_conn]) sign
      | [] ->
        let* qsign = quote_sign_codes (List.combine field_names codes) univ in
        RM.ret @@ S.CodeSignature qsign
    in go [] [] [] sign

  let patch (sig_tac : T.Chk.tac) (tacs : Ident.user -> T.Chk.tac option) : T.Chk.tac =
    univ_tac "Univ.patch" @@ fun univ ->
    let* code = T.Chk.run sig_tac univ in
    let* vcode = RM.lift_ev @@ Sem.eval code in
    let* tp = RM.lift_cmp @@ Sem.do_el vcode in
    let* whnf_tp = RM.lift_cmp @@ Sem.whnf_tp_ tp in
    match whnf_tp with
    | D.ElStable (`Signature sign) ->
      patch_fields sign tacs univ
    | _ ->
      RM.expected_connective `Signature whnf_tp

  let total (vsign : (Ident.user * D.con) list) (vtm : D.con) : T.Chk.tac =
    univ_tac "Univ.total" @@ fun univ ->
    let (sign_names, vsign_codes) = List.split vsign in
    let* qsign = quote_sign_codes vsign univ in
    (* See [NOTE: Sig Code Quantifiers]. *)
    let* fib_tp =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.tp univ @@ fun univ ->
      Splice.cons vsign_codes @@ fun sign_codes ->
      Splice.term @@ TB.pis ~idents:(sign_names :> Ident.t list) sign_codes @@ fun _ -> univ
    in
    let* fib =
      RM.lift_cmp @@
      Sem.splice_tm @@
      Splice.con vtm @@ fun tm ->
      Splice.term @@ TB.lams (sign_names :> Ident.t list) @@ fun args -> TB.el_out @@ TB.ap tm [TB.el_in @@ TB.struct_ @@ List.combine sign_names args]
    in
    let+ qfib = RM.quote_con fib_tp fib in
    S.CodeSignature (qsign @ [`User ["fib"], qfib])

  let ext (n : int) (tac_fam : T.Chk.tac) (tac_cof : T.Chk.tac) (tac_bdry : T.Chk.tac) : T.Chk.tac =
    univ_tac "Univ.ext" @@ fun univ ->
    let* tcof =
      let* tp_cof_fam = RM.lift_cmp @@ Sem.splice_tp @@ Splice.term @@ TB.cube n @@ fun _ -> TB.tp_cof in
      RM.globally @@ T.Chk.run tac_cof tp_cof_fam
    in
    let* cof = RM.lift_ev @@ EvM.drop_all_cons @@ Sem.eval tcof in
    let* tfam =
      let* tp_fam = RM.lift_cmp @@ Sem.splice_tp @@ Splice.tp univ @@ fun univ -> Splice.term @@ TB.cube n @@ fun _ -> univ in
      T.Chk.run tac_fam tp_fam
    in
    let+ tbdry =
      let* fam = RM.lift_ev @@ Sem.eval tfam in
      let* tp_bdry =
        RM.lift_cmp @@ Sem.splice_tp @@
        Splice.con cof @@ fun cof ->
        Splice.con fam @@ fun fam ->
        Splice.term @@
        TB.cube n @@ fun js ->
        TB.pi (TB.tp_prf @@ TB.ap cof js) @@ fun _ ->
        TB.el @@ TB.ap fam js
      in
      T.Chk.run tac_bdry tp_bdry
    in
    S.CodeExt (n, tfam, `Global tcof, tbdry)

  let infer_nullary_ext : T.Chk.tac =
    T.Chk.rule ~name:"Univ.infer_nullary_ext" @@ function
    | ElStable (`Ext (0,code ,`Global (Cof cof),bdry)) ->
      let* cof = RM.lift_cmp @@ Sem.cof_con_to_cof cof in
      let* () = Cof.assert_true cof in
      let* tp = RM.lift_cmp @@
        Sem.splice_tp @@
        Splice.con code @@ fun code ->
        Splice.term @@ TB.el code
      in
      let* tm = RM.lift_cmp @@
        Sem.splice_tm @@
        Splice.con bdry @@ fun bdry ->
        Splice.term @@
        TB.ap bdry [TB.prf]
      in
      let+ ttm = RM.lift_qu @@ Qu.quote_con tp tm in
      S.ElIn (S.SubIn ttm)
    | tp -> RM.expected_connective `ElExt tp

  let code_v (tac_dim : T.Chk.tac) (tac_pcode: T.Chk.tac) (tac_code : T.Chk.tac) (tac_pequiv : T.Chk.tac) : T.Chk.tac =
    univ_tac "Univ.code_v" @@ fun _univ ->
    let* r = T.Chk.run tac_dim D.TpDim in
    let* vr : D.dim =
      let* vr_con = RM.lift_ev @@ Sem.eval r in
      RM.lift_cmp @@ Sem.con_to_dim vr_con
    in
    let* pcode =
      let tp_pcode = D.Pi (D.TpPrf (CofBuilder.eq0 vr), Ident.anon, D.const_tp_clo D.Univ) in
      T.Chk.run tac_pcode tp_pcode
    in
    let* code = T.Chk.run tac_code D.Univ in
    let+ pequiv =
      T.Chk.run tac_pequiv @<<
      let* vpcode = RM.lift_ev @@ Sem.eval pcode in
      let* vcode = RM.lift_ev @@ Sem.eval code in
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.Macro.tp_pequiv_in_v ~r:vr ~pcode:vpcode ~code:vcode
    in
    S.CodeV (r, pcode, code, pequiv)

  let coe (tac_fam : T.Chk.tac) (tac_src : T.Chk.tac) (tac_trg : T.Chk.tac) (tac_tm : T.Chk.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Univ.coe" @@
    let* piuniv =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.term @@
      TB.pi TB.tp_dim @@ fun _i ->
      TB.univ
    in
    let* fam = T.Chk.run tac_fam piuniv in
    let* src = T.Chk.run tac_src D.TpDim in
    let* trg = T.Chk.run tac_trg D.TpDim in
    let* fam_src = RM.lift_ev @@ Sem.eval_tp @@ S.El (S.Ap (fam, src)) in
    let+ tm = T.Chk.run tac_tm fam_src
    and+ fam_trg = RM.lift_ev @@ Sem.eval_tp @@ S.El (S.Ap (fam, trg)) in
    S.Coe (fam, src, trg, tm), fam_trg


  let hcom_bdy_tp tp r phi =
    RM.lift_cmp @@
    Sem.splice_tp @@
    Splice.con r @@ fun src ->
    Splice.con phi @@ fun cof ->
    Splice.tp tp @@ fun vtp ->
    Splice.term @@
    TB.pi TB.tp_dim @@ fun i ->
    TB.pi (TB.tp_prf (TB.join [TB.eq i src; cof])) @@ fun _ ->
    vtp

  let hcom (tac_code : T.Chk.tac) (tac_src : T.Chk.tac) (tac_trg : T.Chk.tac) (tac_cof : T.Chk.tac) (tac_tm : T.Chk.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Univ.hcom" @@
    let* code = T.Chk.run tac_code D.Univ in
    let* src = T.Chk.run tac_src D.TpDim in
    let* trg = T.Chk.run tac_trg D.TpDim in
    let* cof = T.Chk.run tac_cof D.TpCof in
    let* vsrc = RM.lift_ev @@ Sem.eval src in
    let* vcof = RM.lift_ev @@ Sem.eval cof in
    let* vtp = RM.lift_ev @@ Sem.eval_tp @@ S.El code in
    (* (i : dim) -> (_ : [i=src \/ cof]) -> A *)
    let+ tm = T.Chk.run tac_tm @<< hcom_bdy_tp vtp vsrc vcof in
    S.HCom (code, src, trg, cof, tm), vtp

  let com (tac_fam : T.Chk.tac) (tac_src : T.Chk.tac) (tac_trg : T.Chk.tac) (tac_cof : T.Chk.tac) (tac_tm : T.Chk.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Univ.com" @@
    let* piuniv =
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.term @@
      TB.pi TB.tp_dim @@ fun _i ->
      TB.univ
    in
    let* fam = T.Chk.run tac_fam piuniv in
    let* src = T.Chk.run tac_src D.TpDim in
    let* trg = T.Chk.run tac_trg D.TpDim in
    let* cof = T.Chk.run tac_cof D.TpCof in
    let* vfam = RM.lift_ev @@ Sem.eval fam in
    let* vsrc = RM.lift_ev @@ Sem.eval src in
    let* vcof = RM.lift_ev @@ Sem.eval cof in
    (* (i : dim) -> (_ : [i=src \/ cof]) -> A i *)
    let+ tm =
      T.Chk.run tac_tm @<<
      RM.lift_cmp @@
      Sem.splice_tp @@
      Splice.con vfam @@ fun vfam ->
      Splice.con vsrc @@ fun src ->
      Splice.con vcof @@ fun cof ->
      Splice.term @@
      TB.pi TB.tp_dim @@ fun i ->
      TB.pi (TB.tp_prf (TB.join [TB.eq i src; cof])) @@ fun _ ->
      TB.el @@ TB.ap vfam [i]
    and+ vfam_trg = RM.lift_ev @@ Sem.eval_tp @@ S.El (S.Ap (fam, trg)) in
    S.Com (fam, src, trg, cof, tm), vfam_trg
end


module Signature =
struct
  let formation (tacs : T.Tp.tac telescope) : T.Tp.tac =
    let rec form_fields tele =
      function
      | Bind (lbl, tac, tacs) ->
        let* tp = T.Tp.run tac in
        let* vtp = RM.lift_ev @@ Sem.eval_tp tp in
        T.abstract ~ident:(lbl :> Ident.t) vtp @@ fun var -> form_fields (Snoc (tele, (lbl, tp))) (tacs var)
      | Done -> RM.ret @@ S.Signature (BwdLabels.to_list tele)
    in T.Tp.rule ~name:"Signature.formation" @@ form_fields Emp tacs

  let rec find_field_tac (fields : (Ident.user * T.Chk.tac) list) (lbl : Ident.user) : T.Chk.tac option =
    match fields with
    | (lbl', tac) :: _ when Ident.equal lbl lbl'  ->
      Some tac
    | _ :: fields ->
      find_field_tac fields lbl
    | [] ->
      None


  let rec intro_fields phi phi_clo (sign : D.sign) (tacs : Ident.user -> T.Chk.tac option) : (Ident.user * S.t) list m =
    match sign with
    | D.Field (lbl, tp, sign_clo) ->
      let* tac = match tacs lbl, tp with
        | Some tac, _ -> RM.ret tac
        | None, ElStable (`Ext (0,_ ,`Global (Cof cof), _)) ->
          let* cof = RM.lift_cmp @@ Sem.cof_con_to_cof cof in
          begin
            RM.lift_cmp @@ CmpM.test_sequent [] cof |>> function
            | true -> RM.ret Univ.infer_nullary_ext
            | false -> RM.ret @@ Hole.unleash_hole (Ident.user_to_string_opt lbl)
          end
        | None, _ -> RM.ret @@ Hole.unleash_hole (Ident.user_to_string_opt lbl)
      in
      let* tfield = T.Chk.brun tac (tp, phi, D.un_lam @@ D.compose (D.proj lbl) @@ D.Lam (Ident.anon, phi_clo)) in
      let* vfield = RM.lift_ev @@ Sem.eval tfield in
      let* tsign = RM.lift_cmp @@ Sem.inst_sign_clo sign_clo vfield in
      let+ tfields = intro_fields phi phi_clo tsign tacs in
      (lbl, tfield) :: tfields
    | D.Empty ->
      RM.ret []

  let intro (tacs : Ident.user -> T.Chk.tac option) : T.Chk.tac =
    T.Chk.brule ~name:"Signature.intro" @@
    function
    | (D.Signature sign, phi, phi_clo) ->
      let+ fields = intro_fields phi phi_clo sign tacs in
      S.Struct fields
    | (tp, _, _) -> RM.expected_connective `Signature tp

  let proj_tp (sign : D.sign) (tstruct : S.t) (lbl : Ident.user) : D.tp m =
    let rec go =
      function
      | D.Field (flbl, tp, _) when Ident.equal flbl lbl -> RM.ret tp
      | D.Field (flbl, __, clo) ->
        let* vfield = RM.lift_ev @@ Sem.eval @@ S.Proj (tstruct, flbl) in
        let* vsign = RM.lift_cmp @@ Sem.inst_sign_clo clo vfield in
        go vsign
      | D.Empty -> RM.expected_field sign tstruct lbl
    in go sign

  let proj tac lbl : T.Syn.tac =
    T.Syn.rule ~name:"Signature.proj" @@
    let* tstruct, tp = T.Syn.run tac in
    match tp with
    | D.Signature sign ->
      let+ tp = proj_tp sign tstruct lbl in
      S.Proj (tstruct, lbl), tp
    | _ -> RM.expected_connective `Signature tp
end


module El =
struct
  let formation tac =
    T.Tp.rule ~name:"El.formation" @@
    let+ tm = T.Chk.run tac D.Univ in
    S.El tm

  let dest_el tp =
    match tp with
    | D.ElStable con ->
      RM.lift_cmp @@ Sem.unfold_el con
    | _ ->
      RM.expected_connective `El tp

  let intro tac =
    T.Chk.brule ~name:"El.intro" @@ fun (tp, phi, clo) ->
    let* unfolded = dest_el tp in
    let+ tm = T.Chk.brun tac (unfolded, phi, D.un_lam @@ D.compose D.el_out @@ D.Lam (Ident.anon, clo)) in
    S.ElIn tm

  let elim tac =
    T.Syn.rule ~name:"El.elim" @@
    let* tm, tp = T.Syn.run tac in
    let+ unfolded = dest_el tp in
    S.ElOut tm, unfolded
end


module ElV =
struct
  let intro (tac_part : T.Chk.tac) (tac_tot : T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"ElV.intro" @@
    function
    | D.ElUnstable (`V (r, pcode, code, pequiv)), phi, clo ->
      let* part =
        let* tp_part =
          RM.lift_cmp @@ Sem.splice_tp @@
          Splice.con pcode @@ fun pcode ->
          Splice.dim r @@ fun r ->
          Splice.term @@
          TB.pi (TB.tp_prf (TB.eq r TB.dim0)) @@ fun _ ->
          TB.el @@ TB.ap pcode [TB.prf]
        in
        let* bdry_fn =
          RM.lift_cmp @@ Sem.splice_tm @@
          Splice.clo clo @@ fun clo ->
          Splice.term @@
          TB.lam @@ fun _ ->
          TB.lam @@ fun _ ->
          TB.ap clo [TB.prf]
        in
        T.Chk.brun tac_part (tp_part, phi, D.un_lam bdry_fn)
      in
      let* tot =
        let* tp = RM.lift_cmp @@ Sem.do_el code in
        let* vpart = RM.lift_ev @@ Sem.eval part in
        let* bdry_fn =
          RM.lift_cmp @@ Sem.splice_tm @@
          Splice.cof phi @@ fun phi ->
          Splice.clo clo @@ fun clo ->
          Splice.con vpart @@ fun part ->
          Splice.dim r @@ fun r ->
          Splice.con pcode @@ fun pcode ->
          Splice.con code @@ fun code ->
          Splice.con pequiv @@ fun pequiv ->
          Splice.term @@
          TB.lam @@ fun _ -> (* [r=0 ∨ phi] *)
          TB.cof_split
            [TB.eq r TB.dim0, TB.ap (TB.Equiv.equiv_fwd (TB.ap pequiv [TB.prf])) [TB.ap part [TB.prf]];
             phi, TB.vproj r pcode code pequiv @@ TB.ap clo [TB.prf]]
        in
        T.Chk.brun tac_tot (tp, CofBuilder.join [CofBuilder.eq0 r; phi], D.un_lam bdry_fn)
      in
      let* tr = RM.quote_dim r in
      let+ t_pequiv =
        let* tp_pequiv =
          RM.lift_cmp @@ Sem.splice_tp @@
          Splice.Macro.tp_pequiv_in_v ~r ~pcode ~code
        in
        RM.quote_con tp_pequiv pequiv
      in
      S.VIn (tr, t_pequiv, part, tot)
    | tp, _, _ ->
      RM.expected_connective `ElV tp

  let elim (tac_v : T.Syn.tac) : T.Syn.tac =
    T.Syn.rule ~name:"ElV.elim" @@
    let* tm, tp = T.Syn.run tac_v in
    match tp with
    | D.ElUnstable (`V (r, pcode, code, pequiv)) ->
      let* tr = RM.quote_dim r in
      let* tpcode = RM.quote_con (D.Pi (D.TpPrf (CofBuilder.eq0 r), Ident.anon, D.const_tp_clo D.Univ)) pcode in
      let* tcode = RM.quote_con D.Univ code in
      let* t_pequiv =
        let* tp_pequiv =
          RM.lift_cmp @@ Sem.splice_tp @@
          Splice.Macro.tp_pequiv_in_v ~r ~pcode ~code
        in
        RM.quote_con tp_pequiv pequiv
      in
      let vproj = S.VProj (tr, tpcode, tcode, t_pequiv, tm) in
      let* tp_vproj = RM.lift_cmp @@ Sem.do_el code in
      RM.ret (vproj, tp_vproj)
    | _ ->
      RM.expected_connective `ElV tp
end

module ElHCom =
struct
  let intro (tac_walls : T.Chk.tac) (tac_cap : T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"ElHCom.intro" @@
    function
    | D.ElUnstable (`HCom (r, r', phi, bdy)), psi, psi_clo ->
      let* twalls =
        let* tp_walls =
          RM.lift_cmp @@ Sem.splice_tp @@
          Splice.cof phi @@ fun phi ->
          Splice.con bdy @@ fun bdy ->
          Splice.dim r' @@ fun r' ->
          Splice.term @@ TB.pi (TB.tp_prf phi) @@ fun _ -> TB.el @@ TB.ap bdy [r'; TB.prf]
        in
        let* bdry_fn =
          RM.lift_cmp @@ Sem.splice_tm @@
          Splice.clo psi_clo @@ fun psi_clo ->
          Splice.term @@
          TB.lam @@ fun _ -> (* [psi] *)
          TB.lam @@ fun _ -> (* [phi] *)
          TB.ap psi_clo [TB.prf]
        in
        T.Chk.brun tac_walls (tp_walls, psi, D.un_lam bdry_fn)
      in
      let+ tcap =
        let* walls = RM.lift_ev @@ Sem.eval twalls in
        let* tp_cap =
          RM.lift_cmp @@ Sem.splice_tp @@
          Splice.con bdy @@ fun bdy ->
          Splice.dim r @@ fun r ->
          Splice.term @@ TB.el @@ TB.ap bdy [r; TB.prf]
        in
        let* bdry_fn =
          RM.lift_cmp @@ Sem.splice_tm @@
          Splice.dim r @@ fun r ->
          Splice.dim r' @@ fun r' ->
          Splice.cof phi @@ fun phi ->
          Splice.cof psi @@ fun psi ->
          Splice.clo psi_clo @@ fun psi_clo ->
          Splice.con walls @@ fun walls ->
          Splice.con bdy @@ fun bdy ->
          Splice.term @@
          TB.lam @@ fun _ -> (* [phi ∨ psi] *)
          TB.cof_split
            [psi, TB.cap r r' phi bdy @@ TB.ap psi_clo [TB.prf];
             phi, TB.coe (TB.lam ~ident:(Ident.machine "i") @@ fun i -> TB.ap bdy [i; TB.prf]) r' r (TB.ap walls [TB.prf])]
        in
        T.Chk.brun tac_cap (tp_cap, CofBuilder.join [phi; psi], D.un_lam bdry_fn)
      and+ tr = RM.quote_dim r
      and+ tr' = RM.quote_dim r'
      and+ tphi = RM.quote_cof phi in
      S.Box (tr, tr', tphi, twalls, tcap)

    | tp, _, _ ->
      RM.expected_connective `ElHCom tp

  let elim (tac_box : T.Syn.tac) : T.Syn.tac =
    T.Syn.rule ~name:"ElHCom.elim" @@
    let* box, box_tp = T.Syn.run tac_box in
    match box_tp with
    | D.ElUnstable (`HCom (r, r', phi, bdy)) ->
      let+ tr = RM.quote_dim r
      and+ tr' = RM.quote_dim r'
      and+ tphi = RM.quote_cof phi
      and+ tbdy =
        let* tp_bdy = Univ.hcom_bdy_tp D.Univ (D.dim_to_con r) (D.cof_to_con phi) in
        RM.quote_con tp_bdy bdy
      and+ tp_cap =
        let* code_fib = RM.lift_cmp @@ Sem.do_ap2 bdy (D.dim_to_con r) D.Prf in
        RM.lift_cmp @@ Sem.do_el code_fib
      in
      S.Cap (tr, tr', tphi, tbdy, box), tp_cap
    | _ ->
      RM.expected_connective `ElHCom box_tp
end


module Structural =
struct

  let lookup_var id : T.Syn.tac =
    T.Syn.rule ~name:"Structural.lookup_var" @@
    let* res = RM.resolve id in
    match res with
    | `Local ix ->
      let+ tp = RM.get_local_tp ix in
      S.Var ix, tp
    | `Global sym ->
      let+ tp = RM.get_global sym in
      S.Global sym, tp
    | `Unbound ->
      RM.refine_err @@ Err.UnboundVariable id

  let index ix =
    let+ tp = RM.get_local_tp ix in
    S.Var ix, tp

  let level lvl =
    T.Syn.rule ~name:"Structural.level" @@
    let* env = RM.read in
    let ix = RefineEnv.size env - lvl - 1 in
    index ix


  let rec intros ~cells tac =
    match cells with
    | [] ->
      tac
    | cell :: cells ->
      let ident = Env.Cell.ident cell in
      Pi.intro ~ident @@ fun _ ->
      intros ~cells tac

  let unleash_toplevel ~name ?unf_sym ~unf_cof (tac : T.Chk.tac) =
    fun (tp, phi, clo) ->
    let* env = RM.read in
    let cells = Env.locals env in
    let cells_fwd = BwdLabels.to_list cells in
    let* cut =
      RM.globally @@
      let* vtp =
        let* tp = GlobalUtil.multi_pi cells_fwd @@ RM.quote_tp (D.Sub (tp, phi, clo)) in
        RM.lift_ev @@ Sem.eval_tp tp
      in
      let* tp_of_goal =
        RM.lift_cmp @@ Sem.splice_tp @@
        Splice.tp vtp @@ fun vtp ->
        Splice.cof unf_cof @@ fun cof ->
        Splice.term @@ TB.pi (TB.tp_prf cof) @@ fun _ -> vtp
      in
      let* vdef =
        let* tm = tp_of_goal |> T.Chk.run @@ Pi.intro @@ fun _ -> intros ~cells:cells_fwd tac in
        RM.lift_ev @@ Sem.eval tm
      in
      let* tp_sub =
        RM.lift_cmp @@ Sem.splice_tp @@
        Splice.tp vtp @@ fun vtp ->
        Splice.con vdef @@ fun vtm ->
        Splice.cof unf_cof @@ fun cof ->
        Splice.term @@ TB.sub vtp cof @@ fun prf -> TB.ap vtm [prf]
      in
      let* sym = RM.add_global ~unfolder:unf_sym ~shadowing:false name tp_sub in
      let hd = D.UnstableCut ((D.Global sym, []), D.KSubOut (unf_cof, D.const_tm_clo vdef)) in
      RM.ret @@ GlobalUtil.multi_ap cells (hd, [])
    in
    let+ tm = RM.quote_cut cut in
    S.SubOut tm

  let abstract ~name (tac : T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"Structural.abstract" @@ fun goal ->
    let name = Option.value name ~default:Ident.anon in
    let* unf_sym = RM.add_global ~unfolder:None ~shadowing:false (Ident.unfolder name) D.TpDim in
    let* unf_dim = RM.eval @@ S.Global unf_sym in
    let* unf_cof = RM.lift_cmp @@ Sem.con_to_cof @@ D.CofBuilder.eq1 unf_dim in
    unleash_toplevel ~name ~unf_sym ~unf_cof tac goal

  let unfold (unfoldings : Ident.t list) (tac : T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"Structural.unfold" @@ fun goal ->
    let* unf_cof =
      let* syms = RM.resolve_unfolder_syms unfoldings in
      let* dims = syms |> RMU.map @@ fun sym -> RM.eval @@ S.Global sym in
      RM.lift_cmp @@
      Sem.con_to_cof @@
      D.CofBuilder.meet @@
      List.map D.CofBuilder.eq1 dims
    in
    unleash_toplevel ~name:(Ident.blocked unfoldings) ~unf_cof tac goal

  let generalize ident (tac : T.Chk.tac) : T.Chk.tac =
    T.Chk.rule ~name:"Structural.generalize" @@
    fun tp ->
    let* env = RM.read in
    let* lvl =
      RM.resolve ident |>>
      function
      | `Local ix -> RM.ret @@ RefineEnv.size env - ix - 1
      | _ -> RM.refine_err @@ Err.UnboundVariable ident
    in

    let cells = Env.locals env in
    let cells_fwd = BwdLabels.to_list cells in

    let* cut =
      RM.globally @@
      let* global_tp =
        let* tp = GlobalUtil.multi_pi cells_fwd @@ RM.quote_tp tp in
        RM.lift_ev @@ Sem.eval_tp tp
      in
      let* vdef =
        let prefix = List.take lvl cells_fwd in
        let* tm = global_tp |> T.Chk.run @@ intros ~cells:prefix tac in
        RM.lift_ev @@ Sem.eval tm
      in
      let* tp_sub =
        RM.lift_cmp @@ Sem.splice_tp @@
        Splice.tp global_tp @@ fun vtp ->
        Splice.con vdef @@ fun vtm ->
        Splice.term @@
        TB.sub vtp TB.top @@ fun _ -> vtm
      in
      let* sym = RM.add_global ~unfolder:None ~shadowing:true Ident.anon tp_sub in
      let top = Kado.Syntax.Free.top in
      let hd = D.UnstableCut ((D.Global sym, []), D.KSubOut (top, D.const_tm_clo vdef)) in
      RM.ret @@ GlobalUtil.multi_ap cells (hd, [])
    in
    RM.quote_cut cut

  let let_ ?(ident = Ident.anon) (tac_def : T.Syn.tac) (tac_bdy : T.var -> T.Chk.tac) : T.Chk.tac =
    T.Chk.brule ~name:"Structural.let_" @@ fun goal ->
    let* tdef, tp_def = T.Syn.run tac_def in
    let* vdef = RM.lift_ev @@ Sem.eval tdef in
    let* tbdy =
      let* const_vdef =
        RM.lift_cmp @@ Sem.splice_tm @@ Splice.con vdef @@ fun vdef ->
        Splice.term @@ TB.lam @@ fun _ -> vdef
      in
      T.abstract ~ident (D.Sub (tp_def, CofBuilder.top, D.un_lam const_vdef)) @@ fun var ->
      T.Chk.brun (tac_bdy var) goal
    in
    RM.ret @@ S.Let (S.SubIn tdef, ident, tbdy)

  let let_syn ?(ident = Ident.anon) (tac_def : T.Syn.tac) (tac_bdy : T.var -> T.Syn.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Structural.let_syn" @@
    let* tdef, tp_def = T.Syn.run tac_def in
    let* vdef = RM.lift_ev @@ Sem.eval tdef in
    let* tbdy, tbdytp =
      let* const_vdef =
        RM.lift_cmp @@ Sem.splice_tm @@ Splice.con vdef @@ fun vdef ->
        Splice.term @@ TB.lam @@ fun _ -> vdef
      in
      T.abstract ~ident (D.Sub (tp_def, CofBuilder.top, D.un_lam const_vdef)) @@ fun var ->
      let* tbdy, bdytp = T.Syn.run @@ tac_bdy var in
      let* tbdytp = RM.quote_tp bdytp in
      RM.ret (tbdy, tbdytp)
    in
    let* bdytp = RM.lift_ev @@ EvM.append [D.SubIn vdef] @@ Sem.eval_tp tbdytp in
    RM.ret (S.Let (S.SubIn tdef, ident, tbdy), bdytp)

end


module Nat =
struct
  let formation =
    T.Tp.rule ~name:"Nat.formation" @@
    RM.ret S.Nat

  let assert_nat =
    function
    | D.Nat -> RM.ret ()
    | tp -> RM.expected_connective `Nat tp

  let rec int_to_term =
    function
    | 0 -> S.Zero
    | n -> S.Suc (int_to_term (n - 1))

  let literal n : T.Chk.tac =
    T.Chk.rule ~name:"Nat.literal" @@
    fun tp ->
    let+ () = assert_nat tp in
    int_to_term n

  let suc tac : T.Chk.tac =
    T.Chk.rule ~name:"Nat.suc" @@
    fun tp ->
    let* () = assert_nat tp in
    let+ t = T.Chk.run tac tp in
    S.Suc t

  let elim (tac_mot : T.Chk.tac) (tac_case_zero : T.Chk.tac) (tac_case_suc : T.Chk.tac) (tac_scrut : T.Syn.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Nat.elim" @@
    let* tscrut, nattp = T.Syn.run tac_scrut in
    let* () = assert_nat nattp in
    let* tmot =
      T.Chk.run tac_mot @<<
      RM.lift_cmp @@ Sem.splice_tp @@ Splice.term @@
      TB.pi TB.nat @@ fun _ -> TB.univ
    in
    let* vmot = RM.lift_ev @@ Sem.eval tmot in

    let* tcase_zero =
      let* code = RM.lift_cmp @@ Sem.do_ap vmot D.Zero in
      let* tp = RM.lift_cmp @@ Sem.do_el code in
      T.Chk.run tac_case_zero tp
    in

    let* tcase_suc =
      let* suc_tp =
        RM.lift_cmp @@ Sem.splice_tp @@
        Splice.con vmot @@ fun mot ->
        Splice.term @@
        TB.pi TB.nat @@ fun x ->
        TB.pi (TB.el (TB.ap mot [x])) @@ fun _ih ->
        TB.el @@ TB.ap mot [TB.suc x]
      in
      T.Chk.run tac_case_suc suc_tp
    in

    let+ fib_scrut =
      let* vscrut = RM.lift_ev @@ Sem.eval tscrut in
      let* code = RM.lift_cmp @@ Sem.do_ap vmot vscrut in
      RM.lift_cmp @@ Sem.do_el code
    in

    S.NatElim (tmot, tcase_zero, tcase_suc, tscrut), fib_scrut
end


module Circle =
struct
  let formation =
    T.Tp.rule ~name:"Circle.formation" @@
    RM.ret S.Circle

  let assert_circle =
    function
    | D.Circle -> RM.ret ()
    | tp -> RM.expected_connective `Circle tp

  let base =
    T.Chk.rule ~name:"Circle.base" @@ fun tp ->
    let+ () = assert_circle tp in
    S.Base

  let loop tac : T.Chk.tac =
    T.Chk.rule ~name:"Circle.loop" @@ fun tp ->
    let* () = assert_circle tp in
    let+ r = T.Chk.run tac D.TpDim in
    S.Loop r

  let elim (tac_mot : T.Chk.tac) (tac_case_base : T.Chk.tac) (tac_case_loop : T.Chk.tac) (tac_scrut : T.Syn.tac) : T.Syn.tac =
    T.Syn.rule ~name:"Circle.elim" @@
    let* tscrut, circletp = T.Syn.run tac_scrut in
    let* () = assert_circle circletp in
    let* tmot =
      T.Chk.run tac_mot @<<
      RM.lift_cmp @@ Sem.splice_tp @@ Splice.term @@
      TB.pi TB.circle @@ fun _ -> TB.univ
    in
    let* vmot = RM.lift_ev @@ Sem.eval tmot in

    let* tcase_base =
      let* code = RM.lift_cmp @@ Sem.do_ap vmot D.Base in
      let* tp = RM.lift_cmp @@ Sem.do_el code in
      T.Chk.run tac_case_base tp
    in

    let* tcase_loop =
      let* loop_tp =
        RM.lift_cmp @@ Sem.splice_tp @@
        Splice.con vmot @@ fun mot ->
        Splice.term @@
        TB.pi TB.tp_dim @@ fun x ->
        TB.el @@ TB.ap mot [TB.loop x]
      in
      T.Chk.run tac_case_loop loop_tp
    in

    let+ fib_scrut =
      let* vscrut = RM.lift_ev @@ Sem.eval tscrut in
      let* code = RM.lift_cmp @@ Sem.do_ap vmot vscrut in
      RM.lift_cmp @@ Sem.do_el code
    in

    S.CircleElim (tmot, tcase_base, tcase_loop, tscrut), fib_scrut
end
