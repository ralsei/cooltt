type 'a t =
  { view : 'a Namespace.t
  ; export : 'a Namespace.t
  }

let empty = {view = Namespace.empty; export = Namespace.empty}
let inherit_view s = {s with export = Namespace.empty}
let get_export ~prefix s =
  match prefix with
  | None -> s.export
  | Some prefix -> Namespace.prefix prefix s.export
let resolve id s = Namespace.find id s.view

let (let*) = Result.bind
let (let+) x f = Result.map f x

let transform_view ~shadowing ~pp pattern s =
  let+ view = Namespace.transform ~shadowing ~pp pattern s.view in {s with view}
let transform_export ~shadowing ~pp pattern s =
  let+ export = Namespace.transform ~shadowing ~pp pattern s.export in {s with export}
let export_view ~shadowing ~pp pattern s =
  let* to_export = Namespace.transform ~shadowing ~pp pattern s.view in
  let+ export = Namespace.union ~shadowing s.export to_export in
  {s with export}
let add ~shadowing id sym s =
  let* view = Namespace.add ~shadowing id sym s.view in
  let+ export = Namespace.add ~shadowing id sym s.export in
  {view; export}
let include_ ~shadowing ns s =
  let* view = Namespace.union ~shadowing s.view ns in
  let+ export = Namespace.union ~shadowing s.export ns in
  {view; export}
let import ~shadowing ns s =
  let+ view = Namespace.union ~shadowing s.view ns in
  {s with view}
