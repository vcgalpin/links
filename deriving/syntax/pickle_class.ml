(*pp camlp4of *)
module InContext (L : Base.Loc) =
struct
  open Base
  open Utils
  open Types
  open Camlp4.PreCast
  include Base.InContext(L)

  let classname = "Pickle"

  let wrap ctxt decl picklers unpickle =
    <:module_expr< struct type a = $atype ctxt decl$
                          let pickle buffer = function $list:picklers$
                          let unpickle stream = $unpickle$ end >>

  let rec expr t = (Lazy.force obj) # expr t and rhs t = (Lazy.force obj) # rhs t
  and obj = lazy (new make_module_expr ~classname ~variant ~record ~sum)
    
  and polycase ctxt tagspec n : Ast.match_case * Ast.match_case = 
   let picklen = <:expr< Pickle_int.pickle buffer $`int:n$ >> in
    match tagspec with
      | Tag (name, args) -> (match args with 
            | None   -> <:match_case< `$name$ -> $picklen$ >>,
                        <:match_case< $`int:n$ -> `$name$ >>
            | Some e -> <:match_case< `$name$ x -> $picklen$;
                                       let module M = $expr ctxt e$ in M.pickle buffer x >>,
                        <:match_case< $`int:n$ -> let module M = $expr ctxt e$ in 
                                       `$name$ (M.unpickle stream) >>)
      | Extends t -> 
          let patt, guard, cast = cast_pattern ctxt t in
            <:match_case< $patt$ when $guard$ -> 
                          let module M = $expr ctxt t$ in 
                            $picklen$; M.pickle buffer $cast$ >>,
            <:match_case< $`int:n$ -> let module M = $expr ctxt t$ 
                                       in (M.unpickle stream :> a) >>

  and case ctxt : Types.summand -> int -> Ast.match_case * Ast.match_case = fun (name,args) n ->
      match args with 
        | [] -> (<:match_case< $uid:name$ -> Pickle_int.pickle buffer $`int:n$ >>,
                 <:match_case< $`int:n$ -> $uid:name$ >>)
        | _ -> 
        let patt, exp = tuple (List.length args) in
        <:match_case< $uid:name$ $patt$ -> 
                      Pickle_int.pickle buffer $`int:n$;
                      let module M = $expr ctxt (`Tuple args)$ 
                       in M.pickle buffer $exp$ >>,
        <:match_case< $`int:n$ -> 
                      let module M = $expr ctxt (`Tuple args)$ 
                       in let $patt$ = M.unpickle stream in $uid:name$ $exp$  >>
    
  and field ctxt : Types.field -> Ast.expr * Ast.expr = function
    | (name, ([], t), _) -> 
        <:expr< let module M = $expr ctxt t$ in M.pickle buffer $lid:name$ >>,
        <:expr< let module M = $expr ctxt t$ in M.unpickle stream >>
    | f -> raise (Underivable ("Pickle cannot be derived for record types with polymorphic fields")) 

  and sum ctxt ((tname,_,_,_) as decl) summands = 
    let msg = "Unexpected tag when unpickling " ^ tname ^ ": " in
    let picklers, unpicklers = 
      List.split (List.map2 (case ctxt) summands (List.range 0 (List.length summands))) in
      wrap ctxt decl picklers <:expr< match Pickle_int.unpickle stream with $list:unpicklers$ 
                                        | n -> raise (Unpickling_failure ($str:msg$ ^ string_of_int n)) >>

  and record ctxt decl fields = 
    let picklers, unpicklers = 
      List.split (List.map (field ctxt) fields) in
    let unpickle = 
      List.fold_right2
        (fun (field,_,_) unpickler e -> 
           <:expr< let $lid:field$ = $unpickler$ in $e$ >>)
        fields
        unpicklers
        (record_expression fields) in
      wrap ctxt decl
            [ <:match_case< $record_pattern fields$ -> $List.fold_left1 seq picklers$ >>]
            unpickle

   and variant ctxt decl (_, tags) = 
    let msg = "Unexpected tag when unpickling polymorphic variant: " in
    let picklers, unpicklers = 
      List.split (List.map2 (polycase ctxt) tags (List.range 0 (List.length tags))) in
      wrap ctxt decl picklers <:expr< match Pickle_int.unpickle stream with $list:unpicklers$
                                         | n -> raise (Unpickling_failure ($str:msg$ ^ string_of_int n)) >>
end

let _ = Base.register "Pickle"
  ((fun (loc, context, decls) -> 
     let module M = InContext(struct let loc = loc end) in
       M.generate ~context ~decls ~make_module_expr:M.rhs ~classname:M.classname
         ~default_module:"Pickle_defaults" ()),
   (fun (loc, context, decls) -> 
      let module M = InContext(struct let loc = loc end) in
        M.gen_sigs ~context ~decls ~classname:M.classname))

