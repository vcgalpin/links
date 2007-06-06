(*pp camlp4of *)
(* More convenient representation for types, and translation from the
   Camlp4 representation *)

open Utils

(* auxiliary definitions *)
type name = string
type qname = name list
module NameMap = StringMap
module NameSet = Set.Make(String)

type param = name * [`Plus | `Minus] option

(* no support for private types yet *)
type decl = name * param list
    * [`Fresh of expr option (* "equation" *) * repr | `Expr of expr | `Variant of variant | `Nothing]
    * constraint_ list
and repr = 
    Sum of summand list
  | Record of field list
and field = name * poly_expr * [`Mutable | `Immutable]
and summand = name * expr list
and constraint_ = expr * expr
and expr =  (* elements that can be nested *)
    [ `Param of param
    | `Underscore
    | `Label of ([`Optional|`NonOptional] * name * expr * expr)
    | `Function of (expr * expr)
    | `Constr of (qname * expr list)
    | `Tuple of expr list
    | `Object of [`NYI]
    | `Class of [`NYI] ]
and poly_expr = param list * expr
    (* no support for < > variants yet.
       no support for '&' yet.
    *)
and variant = [`Gt | `Lt | `Eq] * tagspec list
and tagspec = Tag of name * expr option 
              | Extends of expr
type rhs = [`Fresh of expr option * repr | `Expr of expr | `Variant of variant | `Nothing]

class virtual ['result] fold = 
object (self : 'self)
  method virtual crush : 'result list -> 'result

  method decl (d:decl) =
    self#crush (match d with
                  | (_, _, `Fresh (Some e, r), cs) ->
                      self#expr e :: self#repr r :: List.map self#constraint_ cs
                  | (_, _, `Fresh (None, r), cs) ->
                      self#repr r :: List.map self#constraint_ cs
                  | (_, _, `Expr e, cs) ->
                      self#expr e :: List.map self#constraint_ cs
                  | (_, _, `Variant v, cs) ->
                      self#variant v :: List.map self#constraint_ cs
                  | (_, _, `Nothing, cs) -> 
                      List.map self#constraint_ cs)

  method repr r =
    self#crush (match r with
                    | Sum summands ->
                        List.map self#summand summands
                    | Record fields ->
                        List.map self#field fields)
    
  method field (name, pexpr, flag) =
    self#crush [self#poly_expr pexpr]
      
  method summand (_,es) =
    self#crush (List.map self#expr es)

  method constraint_ (e1,e2) =
    self#crush [self#expr e1; self#expr e2]

  method expr e = 
    self#crush (match e with
                    `Param _
                  | `Underscore
                  | `Object _
                  | `Class _ -> []
                  | `Label (_, _, e1, e2) 
                  | `Function (e1, e2) -> [self#expr e1; self#expr e2]
                  | `Constr (_, exprs)
                  | `Tuple exprs  -> List.map self#expr exprs)

  method poly_expr (params,e) =
    self#crush [self#expr e]

  method variant (_,tagspecs) =
    self#crush (List.map self#tagspec tagspecs)

  method tagspec t =
    self#crush (match t with
                    Tag (_, None) -> []
                  | Tag (_, Some e)
                  | Extends e -> [self#expr e])
end

class transform = 
object (self : 'self)

  method decl ((name, params, rhs, constraints):decl) : decl =
    let rhs = match rhs with
      | `Fresh (eopt, repr) -> `Fresh (Option.map (self # expr) eopt, 
                                       self # repr repr)
      | `Expr e -> `Expr (self # expr e)
      | `Variant v -> `Variant (self # variant v)
      | `Nothing -> `Nothing
    in  (name, params, rhs, List.map (self # constraint_) constraints)

  method repr = function
    | Sum summands -> Sum (List.map (self # summand) summands)
    | Record fields -> Record (List.map (self # field) fields)

  method field (name, poly_expr, flag) =
    (name, self # poly_expr poly_expr, flag)
    
  method summand (name, exprs) = 
    (name, List.map (self # expr) exprs)

  method constraint_ (e1, e2) =
    (self#expr e1, self#expr e2)

  method expr = function
    | `Object _
    | `Class _
    | `Param _
    | `Underscore as e -> e
    | `Label (flag, name, e1, e2) -> `Label (flag, name, self # expr e1, self # expr e2)
    | `Function (e1, e2) -> `Function (self # expr e1, self # expr e2)
    | `Constr (qname, exprs) -> `Constr (qname, List.map (self # expr) exprs)
    | `Tuple exprs -> `Tuple (List.map self # expr exprs)

  method poly_expr (params, expr)
    = (params, self # expr expr)

  method variant (t, tagspecs)
    = (t, List.map (self # tagspec) tagspecs)
    
  method tagspec = function
    | Tag (name, eopt) -> Tag (name, Option.map (self # expr) eopt)
    | Extends e -> Extends (self # expr e)
end

module Translate =
struct
  open Camlp4.PreCast

  let param = function
    | Ast.TyQuP (loc, name) -> name, Some `Plus
    | Ast.TyQuM (loc, name) -> name, Some `Minus
    | Ast.TyQuo (loc, name)  -> name, None
    | _ -> assert false

  let params = List.map param

  let split_and = function
    | Ast.TyAnd (_,l,r) -> Left (l,r)
    | t -> Right t

  let split_comma = function
    | Ast.TyCom (_,l,r) -> Left (l,r)
    | t -> Right t

  let split_semi = function
    | Ast.TySem (_,l,r) -> Left (l,r)
    | t -> Right t

  let split_or = function
    | Ast.TyOr (_,l,r) -> Left (l,r)
    | t -> Right t

  let split_amp = function
    | Ast.TyAmp (_,l,r) -> Left (l,r)
    | t -> Right t

  let split_ofamp = function
    | Ast.TyOfAmp (_,l,r) -> Left (l,r)
    | t -> Right t

  let split_star = function
    | Ast.TySta (_,l,r) -> Left (l,r)
    | t -> Right t

  let list (one : Ast.ctyp -> 'a) (split : Ast.ctyp -> (Ast.ctyp * Ast.ctyp, Ast.ctyp) either) : Ast.ctyp -> 'a list = 
    let rec aux = function
      | Ast.TyNil _ -> []
      | ctyp ->
          match split ctyp with
            | Left (l,r) -> aux l @ aux r
            | Right item -> [one item]
    in aux

  let ident : Ast.ident -> name = function
    | Ast.IdAcc _
    | Ast.IdAnt _
    | Ast.IdApp _ -> assert false
    | Ast.IdLid (_, i)
    | Ast.IdUid (_, i) -> i

  let rec qident : Ast.ident -> qname = function
    | Ast.IdAcc (_,l,r) -> qident l @ qident r
    | Ast.IdAnt _
    | Ast.IdApp _ -> assert false
    | Ast.IdLid _
    | Ast.IdUid _ as i -> [ident i]

  type vmap = (name * variant * name option) list

  let fresh_name () = "deriving_" ^ random_id 16

  module WithParams(P : sig val params : param list end) =
  struct
    include P

    let apply_t name = 
      `Constr([name], List.map (fun p -> `Param p) params)

    let rec expr : Ast.ctyp -> expr * vmap  = function
      | Ast.TyObj _ -> `Object `NYI, []
      | Ast.TyCls _ -> `Class `NYI, []
      | Ast.TyQuP (_,_)
      | Ast.TyQuM (_,_)
      | Ast.TyQuo (_,_) as p -> `Param (param p), []
      | Ast.TySum _
      | Ast.TyRec _ -> failwith "top level element found nested"
      | Ast.TyAny _ -> `Underscore, []
      | Ast.TyArr (_,f,t) -> 
          let f, v1 = expr f and t,v2 = expr t in
            `Function (f, t), v1 @ v2
      | Ast.TyApp _ as app -> let app, v = application app in `Constr app, v
      | Ast.TyId (_, i) -> `Constr (qident i, []), []
      | Ast.TyTup (_, t) -> let es, vs = List.split (list expr split_star t) in `Tuple es, List.concat vs
      | Ast.TyVrnEq  (_, t) -> variant t `Eq
      | Ast.TyVrnSup (_, t) -> variant t `Gt
      | Ast.TyVrnInf (_, t) -> variant t `Lt
      | Ast.TyAli (_, _, Ast.TyQuo (_,name)) when List.mem_assoc name params ->
          failwith ("Alias names must be distinct from parameter names for "
                    ^"derived types, but '"^name^" is both an alias and a parameter")
      | Ast.TyAli (_, Ast.TyVrnEq  (_, t), Ast.TyQuo (_,name)) -> variant t ~alias:name `Eq
      | Ast.TyAli (_, Ast.TyVrnSup (_, t), Ast.TyQuo (_,name)) -> variant t ~alias:name `Gt
      | Ast.TyAli (_, Ast.TyVrnInf (_, t), Ast.TyQuo (_,name)) -> variant t ~alias:name `Lt
      | Ast.TyVrnInfSup (_, _, _) -> failwith "handling of [ < > ] types is not yet implemented"
      | Ast.TyLab _ -> failwith "deriving does not handle label types"
      | e -> failwith ("unexpected type at expr : " ^ Utils.DumpAst.ctyp e)
    and tagspec = function
      | Ast.TyVrn (_,tag)                  -> Tag (tag, None), []
      | Ast.TyOf (_, Ast.TyVrn (_,tag), t) -> 
          let es, vs = List.split (list expr split_comma t) in 
            Tag (tag, Some (`Tuple es)), List.concat vs
      | t                                  -> let e, v = expr t in Extends e, v
    and application : Ast.ctyp -> (qname * expr list) * vmap = function
      | Ast.TyApp (_, (Ast.TyApp _ as a), t) -> 
          let (tcon, args), vs = application a in
          let e, vs' = expr t in
            (tcon, args @ [e]), vs @ vs'
      | Ast.TyApp (_, (Ast.TyId (_, tcon)), t) -> 
          let e, v = expr t in (qident tcon, [e]), v
      | _ -> assert false
    and variant tags ?alias spec = 
      let name = fresh_name () in
      let tags, vs = List.split (list tagspec split_or tags) in
        (apply_t name, 
         [name, (spec, tags), alias] @ List.concat vs)
    let rec polyexpr : Ast.ctyp -> poly_expr * vmap = function
      | Ast.TyPol (_, ps, t) -> 
          begin match polyexpr t with 
            | (ps',t'), [] -> (list param split_comma ps @ ps', t'), []
            |  _ -> failwith ("deriving does not handle polymorphic variant "
                              ^"definitions within polymorphic record field types")
          end
      | t -> let e, v = expr t in ([], e), v


    let field : Ast.ctyp -> field * vmap = function 
      | Ast.TyCol (_, Ast.TyId (_,name), Ast.TyMut (_, t)) ->
          let p, v = polyexpr t in (ident name, p, `Mutable), v
      | Ast.TyCol (_, Ast.TyId (_,name), t) ->
          let p, v = polyexpr t in (ident name, p, `Immutable), v
      | _ -> assert false

    let summand : Ast.ctyp -> summand * vmap = function 
      | Ast.TyId (_, c)                  -> (ident c, []), []
      | Ast.TyOf (_, Ast.TyId (_, c), t) -> 
          let es, vs = List.split (list expr split_and t) in (ident c, es), List.concat vs
      | _                                -> assert false

    let toplevel : Ast.ctyp -> rhs * vmap  = function
      | Ast.TyRec (loc, fields) -> 
          let fields, vs = List.split (list field split_semi fields) in 
            `Fresh (None, Record fields), List.concat vs
      | Ast.TySum (loc, summands) -> 
          let summands, vs = List.split (list summand split_or summands) in
            `Fresh (None, Sum summands), List.concat vs
      | Ast.TyVrnEq (_, t)  -> 
          let es, vs = List.split (list tagspec split_or t) in
            `Variant (`Eq, es), List.concat vs
      | Ast.TyVrnSup (_, t) ->
          let es, vs = List.split (list tagspec split_or t) in
            `Variant (`Gt, es), List.concat vs 
      | Ast.TyVrnInf (_, t) ->
          let es, vs = List.split (list tagspec split_or t) in
            `Variant (`Lt, es), List.concat vs
      | Ast.TyNil _ -> `Nothing, []
      | Ast.TyVrnInfSup (_, _, _) -> failwith "handling of [ < > ] types is not yet implemented"
      | Ast.TyPrv _ -> failwith "deriving does not handle private types"
      | t -> let e, v = expr t in `Expr e, v

    let constraints : (Ast.ctyp * Ast.ctyp) list -> constraint_ list * vmap = 
      fun cs ->
        List.fold_right
          (fun (c1,c2) (es,vs) -> 
             let e1,v1 = expr c1 
             and e2,v2 = expr c2
             in ((e1,e2)::es), (v1 @ v2 @ vs))
          cs
          ([],[])

    let declify = 
      let declify1 (name, variant, alias) : decl * (name * expr) option = 
        (name, params, `Variant variant, []), Option.map (fun a -> a, apply_t name) alias in
        List.map declify1
  end

  type alias_map = expr NameMap.t
  let build_alias_map : (name * expr) option list -> alias_map = fun m ->
    NameMap.fromList (List.concat_map (function None -> [] | Some e -> [e]) m)

  let split : Ast.ctyp -> Ast.ctyp list =
    let rec aux t = match split_and t with
      | Left (l, r) -> aux l @ aux r
      | Right t -> [t]
    in aux
       
  let rec decl : Ast.ctyp -> decl list * alias_map = function
    | Ast.TyDcl (loc, name, ps, rhs, cs) ->
        let module P = WithParams(struct let params = params ps end) in
        let tl, vs = P.toplevel rhs in
        let cs, vcs = P.constraints cs in
        let decls, aliases = List.split (P.declify (vs @ vcs)) in
          [(name, P.params, tl, cs)] @ decls, build_alias_map aliases
    | _ -> assert false
        
  let substitute_aliases : alias_map -> decl -> decl = fun map ->
  object
    inherit transform as super
    method expr = function
      | `Param (p,_) when NameMap.mem p map -> NameMap.find p map
      | e -> super#expr e
  end # decl

  let decls : Ast.ctyp -> decl list =
    fun ctyp -> 
      let decls, aliases = List.split (List.map decl (split ctyp)) in
        List.concat
          (List.map
             (List.map
                (substitute_aliases (NameMap.union_disjoint aliases))) decls)
end

module Untranslate (C:sig val loc : Camlp4.PreCast.Ast.Loc.t end) =
struct
  open Camlp4.PreCast
  open C
    
  let param = function
    | p, None        -> <:ctyp<  '$lid:p$ >>
    | p, Some `Plus  -> <:ctyp< +'$lid:p$ >>
    | p, Some `Minus -> <:ctyp< -'$lid:p$ >>

        let rec qname = function
          | [] -> assert false
          | [x] -> <:ident< $lid:x$ >>
          | x::xs -> <:ident< $uid:x$.$qname xs$ >>

              let unlist join items translate = 
                List.fold_right join (List.map translate items) (Ast.TyNil loc)

  let pair l r = Ast.TySta (loc, l,r)
  let bar l r = <:ctyp< $l$ | $r$ >>
  let semi l r = <:ctyp< $l$ ; $r$ >>
  let comma l r = <:ctyp< $l$ , $r$ >>
  let and_ l r = <:ctyp< $l$ and $r$ >>

  let expr = 
    let rec expr : expr -> Ast.ctyp = function
        `Param p -> param p
      | `Underscore -> <:ctyp< _ >>
      | `Function (f, t) -> <:ctyp< $expr f$ -> $expr t$ >>
      | `Tuple ts -> Ast.TyTup (loc, unlist pair ts expr)
      | `Constr (tcon, args) -> app (Ast.TyId (loc, qname tcon)) args
      | _ -> assert false
    and app f = function
      | []    -> f
      | [x]   -> <:ctyp< $expr x$ $f$ >>
      | x::xs -> app (<:ctyp< $expr x$ $f$ >>) xs
    in expr
         
  let poly (params, t) =
    List.fold_right
      (fun (p : param) (t : Ast.ctyp) -> 
         Ast.TyPol (loc, param p, t))
      params
      (expr t)

  let rhs = 
    let tagspec = function
      | Tag (c, None) -> <:ctyp< `$c$ >>
      | Tag (c, Some t) -> <:ctyp< `$c$ of $expr t$ >>
      | Extends t -> <:ctyp< $expr t$ >> in
    let summand (name, (args : expr list)) =
      let args = unlist and_ args expr in
        <:ctyp< $uid:name$ of $args$ >> in
    let field ((name, t, mut) : field) = match mut with
      | `Mutable   -> <:ctyp< mutable $lid:name$ : $poly t$ >>
      | `Immutable -> <:ctyp<         $lid:name$ : $poly t$ >> in
    let repr = function
      | Sum summands  -> unlist bar summands summand
      | Record fields -> <:ctyp< { $unlist semi fields field$ }>>
    in function
      | `Fresh (None, t) -> repr t
      | `Expr t          -> expr t
      | `Variant (`Eq, tags) -> <:ctyp< [  $unlist bar tags tagspec$ ] >>
      | `Variant (`Gt, tags) -> <:ctyp< [> $unlist bar tags tagspec$ ] >>
      | `Variant (`Lt, tags) -> <:ctyp< [< $unlist bar tags tagspec$ ] >>
      | `Nothing -> <:ctyp< >>

  let constraint_ (e1,e2) = (expr e1, expr e2)

  let decl ((name, params, r, constraints): decl) =
(*    Ast.StTyp (loc,*)
    Ast.TyDcl (loc, name, List.map param params, rhs r, List.map constraint_ constraints)

  let sigdecl ((name, params, r, constraints): decl) =
    Ast.TyDcl (loc, name, List.map param params, rhs r, List.map constraint_ constraints)

end
