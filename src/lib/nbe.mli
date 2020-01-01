exception Nbe_failed of string

(* Main functions for doing a full normalization *)
val normalize : env:Syntax.env -> term:Syntax.t -> tp:Syntax.t -> Syntax.t

(* Functions to pass between various semantic domains *)
val eval : Syntax.t -> Domain.env -> Domain.t
val eval_tp : Syntax.tp -> Domain.env -> Domain.t
val read_back_nf : int -> Domain.nf -> Syntax.t (* Note that read_back is referred to as quotation in the paper *)
val read_back_tp : int -> Domain.t -> Syntax.tp
val read_back_ne : int -> Domain.ne -> Syntax.t

val equal_nf : int -> Domain.nf -> Domain.nf -> bool
val equal_ne : int -> Domain.ne -> Domain.ne -> bool
val equal_tp : int -> Domain.t -> Domain.t -> bool

(* Functions to manipulate elements of the semantic domain *)
val do_tp_clos : Syntax.tp Domain.clos -> Domain.t -> Domain.t
val do_tm_clos : Syntax.t Domain.clos -> Domain.t -> Domain.t
