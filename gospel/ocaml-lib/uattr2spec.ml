(**************************************************************************)
(*                                                                        *)
(*  GOSPEL -- A Specification Language for OCaml                          *)
(*                                                                        *)
(*  Copyright (c) 2018- The VOCaL Project                                 *)
(*                                                                        *)
(*  This software is free software, distributed under the MIT license     *)
(*  (as described in file LICENSE enclosed).                              *)
(**************************************************************************)

open Utils
open Oparsetree
open Uast
open Uast_utils

let gospel = "gospel"

let has_prefix ~prefix:p s =
  let l = String.length p in
  String.length s >= l && String.sub s 0 l = p

let is_spec attr = has_prefix ~prefix:gospel attr.attr_name.txt
let is_type_spec = function | Stype _ -> true | _ -> false
let is_val_spec  = function | Sval _  -> true | _ -> false
let is_func_spec = function | Sfunc_spec _ -> true | _ -> false

let get_attr_content attr = match attr.attr_payload with
  | PGospel s -> s, attr.attr_loc | _ -> assert false

let get_type_spec = function
  | Stype (x,_) -> x | _ -> assert false

let get_val_spec = function
  | Sval (x,_) -> x | _ -> assert false

let get_func_spec = function
  | Sfunc_spec (s,_) -> s | _ -> assert false

let split_attr attrs = List.partition is_spec attrs

(** An iterator to check if there are attributes that are GOSPEL
   specification. A warning is printed for each one that is found. *)
let unsupported_gospel =
  let gospel_attribute it at = if is_spec at then
    let loc = at.attr_loc in
    let msg = "Specification not supported" in
    let fmt = !Location.formatter_for_warnings in
    Format.fprintf fmt "@[%a@\n@{<warning>Warning:@} %s@]@."
      Location.print_loc loc msg
  in {Oast_iterator.default_iterator with attribute=gospel_attribute}

let uns_gospel = unsupported_gospel

exception Syntax_error of Location.t
exception Floating_not_allowed of Location.t
exception Orphan_decl_spec of Location.t

let () =
  Location.register_error_of_exn (function
      | Syntax_error loc ->
         Some (Location.errorf ~loc "syntax error")
      | Floating_not_allowed loc ->
         Some (Location.errorf ~loc "floating specification not allowed")
      | Orphan_decl_spec loc ->
         Some (Location.errorf ~loc "orphan specification")
      | _ -> None )

(** Parses the attribute content using the specification
   parser. Raises Syntax_error if syntax errors are found, and
   Ghost_decl if a signature starts with VAL or TYPE: in this case,
   the OCaml parser should be used to parse the signature. *)
let parse_gospel attr =
  let spec,loc = get_attr_content attr in
  let lb = Lexing.from_string spec in
  let open Location in
  let open Lexing in
  init lb loc.loc_start.pos_fname;
  lb.lex_curr_p  <- loc.loc_start;
  lb.lex_abs_pos <- loc.loc_start.pos_cnum;
  try Uparser.spec_init Ulexer.token lb with
    Uparser.Error -> begin
      let loc_start,loc_end = lb.lex_start_p, lb.lex_curr_p in
      let loc = Location.{loc_start; loc_end; loc_ghost=false}  in
      raise (Syntax_error loc) end

(** Calls the OCaml interface parser on the content of the
   attribute. It fails if the OCaml parser parses something that is
   not a type or a val. *)
let ghost_spec attr =
  let spec,loc = get_attr_content attr in
  let lb = Lexing.from_string spec in
  let open Location in
  let open Lexing in
  init lb loc.loc_start.pos_fname;
  lb.lex_curr_p <- loc.loc_start;
  lb.lex_abs_pos <- loc.loc_start.pos_cnum;
  let sign =
    try Oparser.interface Olexer.token lb with
      Oparser.Error -> begin
        let loc_start,loc_end = lb.lex_start_p, lb.lex_curr_p in
        let loc = Location.{loc_start; loc_end; loc_ghost=false}  in
        raise (Syntax_error loc) end in
  match sign with
  | [{psig_desc = (Psig_type (r,td));psig_loc}] ->
     Stype_ghost (r,td,psig_loc)
  | [{psig_desc = (Psig_value vd);psig_loc}] ->
     Sval_ghost (vd,psig_loc)
  | [{psig_desc = (Psig_open od);psig_loc}] ->
     Sopen_ghost (od,psig_loc)
  | _  (* should not happen *)               -> assert false


(** Tries to apply the specification parser and if the parser raises a
   Ghost_decl exception, it tries the OCaml interface parser *)
let attr2spec a = try parse_gospel a with
                  | Ghost_decl -> ghost_spec a

(** It parses the attributes attached to a type declaration and
   returns a new type declaration with a specification and also the
   part of the specification that could not be attached to the type
   declaration (they are probably floating specification). If
   [extra_spec] is provided they are merged with the declaration
   specification. *)
let type_spec ?(extra_spec=[]) t =
  (* no specification attached to unsupported fields *)
  List.iter (fun (c,_)     -> uns_gospel.typ uns_gospel c) t.ptype_params;
  List.iter (fun (c1,c2,_) -> uns_gospel.typ uns_gospel c1;
                              uns_gospel.typ uns_gospel c2) t.ptype_cstrs;
  uns_gospel.type_kind uns_gospel t.ptype_kind;
  (match t.ptype_manifest with
     None -> ()
   | Some m -> uns_gospel.typ uns_gospel m);

  let spec,attr = split_attr t.ptype_attributes in
  let spec = List.map attr2spec spec in

  let tspec,fspec = Utils.split_at_f is_type_spec spec in
  let tspec = List.map get_type_spec tspec in
  let tspec = tspec @ extra_spec in
  let tspec = List.fold_left tspec_union empty_tspec tspec in
  let td = { tname = t.ptype_name;       tparams= t.ptype_params;
             tcstrs = t.ptype_cstrs;     tkind = t.ptype_kind;
             tprivate = t.ptype_private; tmanifest = t.ptype_manifest;
             tattributes = attr;         tspec = tspec;
             tloc = t.ptype_loc;} in
  td, fspec

(** It parses a list of type declarations. If more than one item is
   presented only the last one can have attributes that correspond to
   floating specification. [extra_spec], if provided, is appended to
   the last type declaration specification. Raises
   Floating_not_allowed if floating specification is found in the
   middle of recursive type declaration;*)
let type_declaration ?(extra_spec=[]) t =
  (* when we have a recursive type, we only allow floating spec
     attributes in the last element *)
  let rec get_tspecs = function
  | [] -> [],[]
  | [t] ->
     let td,fspec = type_spec ~extra_spec t in
     [td],fspec
  | t::ts ->
     let td,fspec = type_spec t in
     if fspec != [] then raise (Floating_not_allowed t.ptype_loc);
     let tds,fspec = get_tspecs ts in
     td::tds,fspec in
  let td,fspec = get_tspecs t in
  td, fspec

(** It parses the attributes of a val description. Only the first
   attribute is taken into account for the val specification. All
   other are assumed to be floating specification. *)
let val_description v =
  (* no specification attached to unsupported fields *)
  uns_gospel.typ uns_gospel v.pval_type;

  let spec,attrs =  split_attr v.pval_attributes in
  let spec = List.map attr2spec spec in

  let vd =
    { vname = v.pval_name; vtype = v.pval_type; vprim = v.pval_prim;
      vattributes = attrs; vspec = None;        vloc = v.pval_loc;} in

  match spec with
  | [] -> vd, spec
  | x::xs when is_val_spec x ->
     { vd with vspec = Some (get_val_spec x)}, xs
  | xs -> vd, xs

let mk_svb spvb_pat spvb_expr spvb_attributes spvb_vspec spvb_loc =
  { spvb_pat; spvb_expr; spvb_attributes; spvb_vspec; spvb_loc }

(** It parses floating attributes for specification. If nested
   specification is found in type/val declarations they must be
   type/val specification.

   Raises (1) Floating_not_allowed if nested specification is a
   floating specification; (2) Orphan_decl_spec if floating
   specification is a type declaration or val description*)
let rec floating_specs = function
  | [] -> []
  | Sopen_ghost (od,sloc) :: xs ->
     {sdesc=Sig_ghost_open od; sloc} :: floating_specs xs
  | Sfunction (f,sloc) :: xs ->
     (* Look forward and get floating function specification *)
     let (fun_specs,xs) = split_at_f is_func_spec xs in
     let fun_specs = List.map get_func_spec fun_specs in
     let fun_specs = List.fold_left Uast_utils.fspec_union
                     f.fun_spec fun_specs in
     let f = {f with fun_spec = fun_specs } in
     {sdesc=Sig_function f;sloc} :: floating_specs xs
  | Saxiom (a,sloc) :: xs ->
     {sdesc=Sig_axiom a;sloc} :: floating_specs xs
  | Stype_ghost (r,td,sloc) :: xs ->
     (* Look forward and get floating type specification *)
     let tspecs,xs = split_at_f is_type_spec xs in
     let extra_spec = List.map get_type_spec tspecs in
     let td,fspec = type_declaration ~extra_spec td in
     (* if there is nested specification they must refer to the ghost type *)
     if fspec != [] then
       raise (Floating_not_allowed sloc);
     let sdesc = Sig_ghost_type (r,td) in
     {sdesc;sloc} :: floating_specs xs
  | Sval_ghost (vd,sloc) :: xs ->
     let vd,fspec = val_description vd in
     (* if there is nested specification they must refer to the ghost val *)
     if fspec != [] then
       raise (Floating_not_allowed sloc);
     let vd,xs =
       if vd.vspec = None then
         (* val spec might be in the subsequent floating specs *)
         match xs with
         | Sval (vs,_) :: xs -> {vd with vspec=Some vs}, xs
         | _ -> vd, xs
       else (* this val already contains a spec *)
         vd, xs in

     let sdesc = Sig_ghost_val vd in
     {sdesc;sloc} :: floating_specs xs
  | Stype (_,loc) :: _ -> raise (Orphan_decl_spec loc)
  | Sval (_,loc)  :: _ -> raise (Orphan_decl_spec loc)
  | Sfunc_spec (_,loc) :: _ -> raise (Orphan_decl_spec loc)

(** Raises warning if specifications are found in inner attributes and
   simply creates a s_with_constraint. *)
let with_constraint c =
  uns_gospel.with_constraint uns_gospel c;

  let no_spec_type_decl t =
    { tname = t.ptype_name; tparams = t.ptype_params;
      tcstrs = t.ptype_cstrs; tkind = t.ptype_kind;
      tprivate = t.ptype_private; tmanifest = t.ptype_manifest;
      tattributes = t.ptype_attributes;
      tspec = empty_tspec; tloc = t.ptype_loc;}
  in match c with
  | Pwith_type (l,t) -> Wtype (l,no_spec_type_decl t)
  | Pwith_module (l1,l2) -> Wmodule (l1,l2)
  | Pwith_typesubst (l,t) -> Wtypesubst (l,no_spec_type_decl t)
  | Pwith_modsubst (l1,l2) -> Wmodsubst (l1,l2)


let get_spec_attrs attrs =
  let specs,attrs = split_attr attrs in
  attrs, floating_specs (List.map attr2spec specs)

(** Translats OCaml signatures with specification attached to
   attributes into our intermediate representation. Beaware,
   prev_floats must be reverted before used *)
let rec signature_ sigs acc prev_floats = match sigs with
  | [] -> acc @ floating_specs (List.rev prev_floats)
  | {psig_desc=Psig_attribute a;
     psig_loc=sloc} :: xs  when (is_spec a) ->
     (* in this special case, we put together all the floating specs
        and only when seing another signature convert them into
        specification *)
     signature_ xs acc (attr2spec a :: prev_floats)
  | {psig_desc;psig_loc=sloc} :: xs ->
     let prev_specs = floating_specs (List.rev prev_floats) in
     let current_specs = match psig_desc with
       | Psig_value v ->
          let vd,fspec = val_description v in
          let current = {sdesc=Sig_val vd;sloc} in
          let attached = floating_specs fspec in
          current :: attached
       | Psig_type (r,t) ->
          let td,fspec = type_declaration t in
          let current = {sdesc=Sig_type (r,td);sloc} in
          let attached = floating_specs fspec in
          current :: attached
       | Psig_attribute a ->
          [{sdesc=Sig_attribute a;sloc}]
       | Psig_module m ->
          let md, spec = module_declaration m in
          {sdesc=Sig_module md;sloc} :: spec
       | Psig_recmodule d ->
          let mds,spec = List.fold_right (fun m (mds,specs) ->
                             let md, spec = module_declaration m in
                             (md::mds,spec @ specs)
                           ) d ([],[]) in
          {sdesc=Sig_recmodule mds;sloc} :: spec
       | Psig_modtype d ->
          let m, spec = module_type_declaration d in
          {sdesc=Sig_modtype m;sloc} :: spec
       | Psig_typext t ->
          let attrs,specs = get_spec_attrs t.ptyext_attributes in
          let t = {t with ptyext_attributes = attrs} in
          uns_gospel.type_extension uns_gospel t;
          [{sdesc=Sig_typext t;sloc}]
       | Psig_exception e ->
          let attrs,specs = get_spec_attrs e.ptyexn_attributes in
          let e = {e with ptyexn_attributes = attrs} in
          uns_gospel.type_exception  uns_gospel e;
          let current = {sdesc=Sig_exception e;sloc} in
          current :: specs
       | Psig_open o ->
          let attrs,specs = get_spec_attrs o.popen_attributes in
          let o = {o with popen_attributes = attrs } in
          uns_gospel.open_description uns_gospel o;
          {sdesc=Sig_open o;sloc} :: specs
       | Psig_include i ->
          let attrs,specs = get_spec_attrs i.pincl_attributes in
          let i = {i with pincl_attributes = attrs} in
          uns_gospel.include_description uns_gospel i;
          [{sdesc=Sig_include i;sloc}]
       | Psig_class c ->
          let c,specs =
            List.fold_right (fun cd (cl,specl) ->
                let attrs,specs = get_spec_attrs cd.pci_attributes in
                let c = {cd with pci_attributes = attrs} in
                uns_gospel.class_description uns_gospel c;
                c::cl, specs @ specl
              ) c ([],[]) in
          {sdesc=Sig_class c;sloc} :: specs
       | Psig_class_type c ->
          let c,specs =
            List.fold_right (fun cd (cl,specl) ->
                let attrs,specs = get_spec_attrs cd.pci_attributes in
                let c = {cd with pci_attributes = attrs} in
                uns_gospel.class_type_declaration uns_gospel c;
                c::cl, specs @ specl
              ) c ([],[]) in
          [{sdesc=Sig_class_type c;sloc}]
       | Psig_extension (e,a) ->
          let attrs,specs = get_spec_attrs a in
          {sdesc=Sig_extension (e,attrs);sloc} :: specs in
     let all_specs = acc @ prev_specs @ current_specs in
     signature_ xs all_specs []

and signature sigs = signature_ sigs [] []

and module_type_desc m =
  match m with
  | Pmty_ident id ->
     Mod_ident id
  | Pmty_signature s ->
     Mod_signature (signature s)
  | Pmty_functor (l,m1,m2) ->
     Mod_functor (l,Utils.opmap module_type m1, module_type m2)
  | Pmty_with (m,c) ->
     Mod_with (module_type m, List.map with_constraint c)
  | Pmty_typeof m ->
     uns_gospel.module_expr uns_gospel m; Mod_typeof m
  | Pmty_extension e -> Mod_extension e
  | Pmty_alias a -> Mod_alias a

and module_type m =
  uns_gospel.attributes uns_gospel m.pmty_attributes;
  { mdesc = module_type_desc m.pmty_desc;
    mloc = m.pmty_loc; mattributes = m.pmty_attributes}

and module_declaration m =
  let attrs, specs = get_spec_attrs m.pmd_attributes in
  let m = { mdname = m.pmd_name; mdtype = module_type m.pmd_type;
    mdattributes = attrs; mdloc = m.pmd_loc } in
  m, specs

and module_type_declaration m =
  let attrs, specs = get_spec_attrs m.pmtd_attributes in
  let mtd = { mtdname = m.pmtd_name;
              mtdtype = Utils.opmap module_type m.pmtd_type;
              mtdattributes = attrs; mtdloc = m.pmtd_loc} in
  mtd, specs

let floating_specs_str = function
  | Sfunction (f, _) ->
      (* TODO: look forward for function specification *)
      Str_function f
  | Saxiom (a, _) ->
      Str_axiom a
  | _ -> assert false (* TODO *)

let mk_s_structure_item ~loc sstr_desc =
  { sstr_desc; sstr_loc = loc }

let mk_s_expression spexp_desc spexp_loc spexp_loc_stack spexp_attributes =
  { spexp_desc; spexp_loc; spexp_loc_stack; spexp_attributes }

let mk_s_module_expr spmod_desc spmod_loc spmod_attributes =
  { spmod_desc; spmod_loc; spmod_attributes }

let rec s_expression expr =
  let loc = expr.pexp_loc in
  let loc_stack = expr.pexp_loc_stack in
  let attributes = expr.pexp_attributes in
  let lbl_expr (lbl, expr) = lbl, s_expression expr in
  let longid_expr (id,  expr) = id,  s_expression expr in
  let case {pc_lhs; pc_guard; pc_rhs} =
    let spc_lhs = pc_lhs in
    let spc_guard = opmap s_expression pc_guard in
    let spc_rhs = s_expression pc_rhs in
    { spc_lhs; spc_guard; spc_rhs } in
  let spexp_desc = function
    | Pexp_ident id ->
        Sexp_ident id
    | Pexp_constant c ->
        Sexp_constant c
    | Pexp_let (rec_flag, vb_list, expr) ->
        Sexp_let (rec_flag, List.map s_value_binding vb_list, s_expression expr)
    | Pexp_function case_list ->
        Sexp_function case_list
    | Pexp_fun (arg, expr_arg, pat, expr) ->
        Sexp_fun (arg, opmap s_expression expr_arg, pat, s_expression expr)
    | Pexp_apply (expr, arg_list) ->
        Sexp_apply (s_expression expr, List.map lbl_expr arg_list)
    | Pexp_match (expr, case_list) ->
        Sexp_match (s_expression expr, List.map case case_list)
    | Pexp_try (expr, case_list) ->
        Sexp_try (s_expression expr, List.map case case_list)
    | Pexp_tuple expr_list ->
        Sexp_tuple (List.map s_expression expr_list)
    | Pexp_construct (id, expr) ->
        Sexp_construct (id, opmap s_expression expr)
    | Pexp_variant (label, expr) ->
        Sexp_variant (label, opmap s_expression expr)
    | Pexp_record (field_list, expression) ->
        let field_list = List.map longid_expr field_list in
        Sexp_record (field_list, opmap s_expression expression)
    | Pexp_field (expr, id) ->
        Sexp_field (s_expression expr, id)
    | Pexp_setfield (expr_rec, field, expr_assign) ->
        Sexp_setfield (s_expression expr_rec, field, s_expression expr_assign)
    | Pexp_array expr_list ->
        Sexp_array (List.map s_expression expr_list)
    | Pexp_ifthenelse (expr1, expr2, expr3) ->
        let expr1 = s_expression expr1 and expr2 = s_expression expr2 in
        Sexp_ifthenelse (expr1, expr2, opmap s_expression expr3)
    | Pexp_sequence (expr1, expr2) ->
        Sexp_sequence (s_expression expr1, s_expression expr2)
    | Pexp_while (expr1, expr2) ->
        Sexp_while (s_expression expr1, s_expression expr2)
    | Pexp_for (pat, expr1, expr2, direction_flag, expr3) ->
        let expr1 = s_expression expr1 and expr2 = s_expression expr2 in
        let expr3 = s_expression expr3 in
        Sexp_for (pat, expr1, expr2, direction_flag, expr3)
    | Pexp_constraint (expr, core_type) ->
        Sexp_constraint (s_expression expr, core_type)
    | Pexp_coerce (expr, core_ty_left, core_ty_right) ->
        Sexp_coerce (s_expression expr, core_ty_left, core_ty_right)
    | Pexp_send (expr, label) ->
        Sexp_send (s_expression expr, label)
    | Pexp_new id ->
        Sexp_new id
    | Pexp_setinstvar (label, expr) ->
        Sexp_setinstvar (label, s_expression expr)
    | Pexp_override label_expr_list ->
        let lbl_expr (lbl, expr) = lbl, s_expression expr in
        Sexp_override (List.map lbl_expr label_expr_list)
    | Pexp_letmodule (id, mod_expr, expr) ->
        Sexp_letmodule (id, mod_expr, s_expression expr)
    | Pexp_letexception (construct, expr) ->
        Sexp_letexception (construct, s_expression expr)
    | Pexp_assert expr ->
        Sexp_assert (s_expression expr)
    | Pexp_lazy expr ->
        Sexp_lazy (s_expression expr)
    | Pexp_poly (expr, cty) ->
        Sexp_poly (s_expression expr, cty)
    | Pexp_object class_str ->
        Sexp_object class_str
    | Pexp_newtype (id, expr) ->
        Sexp_newtype (id, s_expression expr)
    | Pexp_pack mod_expr ->
        Sexp_pack (s_module_expr mod_expr)
    | Pexp_open (override_flag, id, expr) ->
        Sexp_open (override_flag, id, s_expression expr)
    | Pexp_extension extension ->
        Sexp_extension extension
    | Pexp_unreachable ->
        Sexp_unreachable in
  mk_s_expression (spexp_desc expr.pexp_desc) loc loc_stack attributes

and s_module_expr {pmod_desc; pmod_loc; pmod_attributes} =
  let spmod_desc = match pmod_desc with
    | Pmod_ident id ->
        Smod_ident id
    | Pmod_structure str ->
        Smod_structure (structure str)
    | Pmod_functor (id, mod_type, mod_expr) ->
        Smod_functor (id, opmap module_type mod_type, s_module_expr mod_expr)
    | Pmod_apply (mod_expr1, mod_expr2) ->
        Smod_apply (s_module_expr mod_expr1, s_module_expr mod_expr2)
    | Pmod_constraint (mod_expr, mod_type) ->
        Smod_constraint (s_module_expr mod_expr, module_type mod_type)
    | Pmod_unpack expr ->
        Smod_unpack (s_expression expr)
    | Pmod_extension extension ->
        Smod_extension extension in
  mk_s_module_expr spmod_desc pmod_loc pmod_attributes

and structure s = List.map structure_item s

and structure_item str_item =
  let loc = str_item.pstr_loc in
  let str_desc = function
    | Pstr_eval (e, attrs) ->
        Str_eval (s_expression e, attrs)
    | Pstr_value (rec_flag, vb_list) ->
        let vbs = List.map s_value_binding vb_list in
        Str_value (rec_flag, vbs)
    | Pstr_type (rec_flag, type_decl_list) ->
        let td_list, _ = type_declaration type_decl_list in
        Str_type (rec_flag, td_list)
    | Pstr_attribute attr when is_spec attr ->
        let spec = attr2spec attr in
        floating_specs_str spec
    | Pstr_module mod_binding ->
        Str_module (s_module_binding mod_binding)
    | _ -> assert false (* TODO *) in
  mk_s_structure_item (str_desc str_item.pstr_desc) ~loc

and s_value_binding vb_list =
  (* [val_binding v] parses the attributes of a value binding. As for val
     description, only the first attribute is considered as specification. *)
  let val_binding v =
    let spec, attrs = split_attr v.pvb_attributes in
    let spec = List.map attr2spec spec in
    let expr = s_expression v.pvb_expr in
    let vb = mk_svb v.pvb_pat expr v.pvb_attributes None v.pvb_loc in
    match spec with
    | [] -> vb, spec
    | Sval (x, _) :: xs ->
        { vb with spvb_vspec = Some x}, xs
    | xs -> vb, xs in
  (* TODO: take care of those floating specs *)
  let spec, _ = val_binding vb_list in spec

and s_module_binding {pmb_name; pmb_expr; pmb_attributes; pmb_loc} =
  { spmb_expr = s_module_expr pmb_expr; spmb_name = pmb_name;
    spmb_attributes = pmb_attributes; spmb_loc = pmb_loc }
