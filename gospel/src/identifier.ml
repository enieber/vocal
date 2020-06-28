(**************************************************************************)
(*                                                                        *)
(*  GOSPEL -- A Specification Language for OCaml                          *)
(*                                                                        *)
(*  Copyright (c) 2018- The VOCaL Project                                 *)
(*                                                                        *)
(*  This software is free software, distributed under the MIT license     *)
(*  (as described in file LICENSE enclosed).                              *)
(**************************************************************************)

let pp_attr ppf attr = Format.fprintf ppf "[@%s]" attr

let pp_attrs = Format.pp_print_list pp_attr

(** Pre identifiers - not unique - used by parsetree and untyped AST *)

module Preid = struct
  type t = {
    pid_str: string;
    pid_attrs: string list;
    pid_loc: Location.t;
  }

  let pp ppf pid =
    Format.fprintf ppf "%s%a" pid.pid_str pp_attrs pid.pid_attrs

  let create ?(attrs=[]) ?(loc=Location.none) str =
    { pid_str=str; pid_attrs=attrs; pid_loc=loc }

  let add_attr t attr = { t with pid_attrs = attr :: t.pid_attrs }
end

(** Identifiers *)

module Ident = struct
  type t = {
    id_str: string;
    id_attrs: string list;
    id_loc: Location.t;
    id_tag: int;
  }

  let pp =
    let current = Hashtbl.create 0 in
    let output  = Hashtbl.create 0 in
    let current s =
      let x =
        Hashtbl.find_opt current s
        |> Option.fold ~none:0 ~some:succ
      in
      Hashtbl.replace current s x; x
    in
    let str_of_id id =
      try Hashtbl.find output id.id_tag with
      | Not_found ->
          let x = current id.id_str in
          let str = if x = 0 then id.id_str else
              id.id_str ^ "#" ^ string_of_int x in
          Hashtbl.replace output id.id_tag str; str in
    fun ppf t ->
      Format.fprintf ppf "%s%a" (str_of_id t) pp_attrs t.id_attrs

  let create =
    let tag = ref 0 in
    fun ?(attrs=[]) ?(loc=Location.none) str ->
      incr tag;
      {
        id_str = str;
        id_attrs = attrs;
        id_loc = loc;
        id_tag = !tag
      }

  let of_preid (pid: Preid.t) =
    create pid.pid_str ~attrs:pid.pid_attrs ~loc:pid.pid_loc

  let set_loc t loc = { t with id_loc = loc }

  let add_attr t attr = { t with id_attrs = attr :: t.id_attrs }
end

(* utils *)

let prefix s = "prefix " ^ s
let infix  s = "infix "  ^ s
let mixfix s = "mixfix " ^ s

let is_somefix f s =
  let sl = String.split_on_char ' ' s in
  List.length sl > 1 && List.hd sl = f

let is_prefix = is_somefix "prefix"
let is_infix  = is_somefix "infix"
let is_mixfix = is_somefix "mixfix"

(* hard-coded ids *)

let eq    = fresh_id (infix "=")
let neq   = fresh_id (infix "<>")
let none  = fresh_id ("None")
let some  = fresh_id ("Some")
let nil   = fresh_id ("[]")
let cons  = fresh_id (infix "::")

(* pretty-printer *)

let pp = Format.fprintf

let print_attr fmt a = pp fmt "[@%s]" a
let print_attrs = Format.(pp_print_list ~pp_sep:pp_print_space) print_attr

let print_pid fmt pid = pp fmt "%s@ %a" pid.pid_str
                            print_attrs pid.pid_ats
let print_ident =
  let current = Hashtbl.create 0 in
  let output  = Hashtbl.create 0 in
  let current s =
    let x = match Hashtbl.find_opt current s with
      | Some x -> x + 1
      | None -> 0
    in
    Hashtbl.replace current s x; x
  in
  let str_of_id id =
    try Hashtbl.find output id.id_tag with
    | Not_found ->
       let x = current id.id_str in
       let str = if x = 0 then id.id_str else
                   id.id_str ^ "#" ^ string_of_int x in
       Hashtbl.replace output id.id_tag str; str in
  fun fmt id -> pp fmt "%s%a" (str_of_id id)
                  print_attrs (Sattr.elements id.id_ats)
