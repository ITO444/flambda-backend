(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                      Max Slater, Jane Street                           *)
(*                                                                        *)
(*   Copyright 2023 Jane Street Group LLC                                 *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-40-42"]

(* SIMD instruction selection for ARM64 *)

let select_operation _ = None

let pseudoregs_for_operation _ arg res = arg, res

(* for avoiding compilation errors when using them in amd64 *)
type register =
  | Original of int
  | New of int

type vectorized_instruction =
  { operation : Cfg.operation;
    arguments : register array;
    results : register array
  }

let vector_width = 128

let vectorize_operation _ _ : vectorized_instruction list option = None
