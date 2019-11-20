(**************************************************************************)
(*                                                                        *)
(*  GOSPEL -- A Specification Language for OCaml                          *)
(*                                                                        *)
(*  Copyright (c) 2018- The VOCaL Project                                 *)
(*                                                                        *)
(*  This software is free software, distributed under the MIT license     *)
(*  (as described in file LICENSE enclosed).                              *)
(**************************************************************************)

(*@ axiom ax: forall x: float list.
    match x with
    | y :: ys -> y = 2 *)

(* ERROR:
   Line 13
   y is of type float and 2 of type integer
   replace "2" by "2." in line 13 *)
