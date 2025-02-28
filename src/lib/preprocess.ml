(****************************************************************************)
(*     Sail                                                                 *)
(*                                                                          *)
(*  Sail and the Sail architecture models here, comprising all files and    *)
(*  directories except the ASL-derived Sail code in the aarch64 directory,  *)
(*  are subject to the BSD two-clause licence below.                        *)
(*                                                                          *)
(*  The ASL derived parts of the ARMv8.3 specification in                   *)
(*  aarch64/no_vector and aarch64/full are copyright ARM Ltd.               *)
(*                                                                          *)
(*  Copyright (c) 2013-2021                                                 *)
(*    Kathyrn Gray                                                          *)
(*    Shaked Flur                                                           *)
(*    Stephen Kell                                                          *)
(*    Gabriel Kerneis                                                       *)
(*    Robert Norton-Wright                                                  *)
(*    Christopher Pulte                                                     *)
(*    Peter Sewell                                                          *)
(*    Alasdair Armstrong                                                    *)
(*    Brian Campbell                                                        *)
(*    Thomas Bauereiss                                                      *)
(*    Anthony Fox                                                           *)
(*    Jon French                                                            *)
(*    Dominic Mulligan                                                      *)
(*    Stephen Kell                                                          *)
(*    Mark Wassell                                                          *)
(*    Alastair Reid (Arm Ltd)                                               *)
(*                                                                          *)
(*  All rights reserved.                                                    *)
(*                                                                          *)
(*  This work was partially supported by EPSRC grant EP/K008528/1 <a        *)
(*  href="http://www.cl.cam.ac.uk/users/pes20/rems">REMS: Rigorous          *)
(*  Engineering for Mainstream Systems</a>, an ARM iCASE award, EPSRC IAA   *)
(*  KTF funding, and donations from Arm.  This project has received         *)
(*  funding from the European Research Council (ERC) under the European     *)
(*  Union’s Horizon 2020 research and innovation programme (grant           *)
(*  agreement No 789108, ELVER).                                            *)
(*                                                                          *)
(*  This software was developed by SRI International and the University of  *)
(*  Cambridge Computer Laboratory (Department of Computer Science and       *)
(*  Technology) under DARPA/AFRL contracts FA8650-18-C-7809 ("CIFV")        *)
(*  and FA8750-10-C-0237 ("CTSRD").                                         *)
(*                                                                          *)
(*  Redistribution and use in source and binary forms, with or without      *)
(*  modification, are permitted provided that the following conditions      *)
(*  are met:                                                                *)
(*  1. Redistributions of source code must retain the above copyright       *)
(*     notice, this list of conditions and the following disclaimer.        *)
(*  2. Redistributions in binary form must reproduce the above copyright    *)
(*     notice, this list of conditions and the following disclaimer in      *)
(*     the documentation and/or other materials provided with the           *)
(*     distribution.                                                        *)
(*                                                                          *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''      *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED       *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A         *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR     *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,            *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT        *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF        *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND     *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,      *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT      *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF      *)
(*  SUCH DAMAGE.                                                            *)
(****************************************************************************)

(* Simple preprocessor features for conditional file loading *)
module StringSet = Set.Make(String)

let default_symbols =
  List.fold_left (fun set str -> StringSet.add str set) StringSet.empty
    [ "FEATURE_IMPLICITS";
      "FEATURE_CONSTANT_TYPES";
      "FEATURE_BITVECTOR_TYPE";
      "FEATURE_UNION_BARRIER";
    ]

let symbols = ref default_symbols

let have_symbol symbol =
  StringSet.mem symbol !symbols

let clear_symbols () = symbols := default_symbols

let add_symbol str = symbols := StringSet.add str !symbols
                     
let cond_pragma l defs =
  let depth = ref 0 in
  let in_then = ref true in
  let then_defs = ref [] in
  let else_defs = ref [] in

  let push_def def =
    if !in_then then
      then_defs := (def :: !then_defs)
    else
      else_defs := (def :: !else_defs)
  in

  let rec scan = function
    | Parse_ast.DEF_pragma ("endif", _, _) :: defs when !depth = 0 ->
       (List.rev !then_defs, List.rev !else_defs, defs)
    | Parse_ast.DEF_pragma ("else", _, _) :: defs when !depth = 0 ->
       in_then := false; scan defs
    | (Parse_ast.DEF_pragma (p, _, _) as def) :: defs when p = "ifdef" || p = "ifndef" ->
       incr depth; push_def def; scan defs
    | (Parse_ast.DEF_pragma ("endif", _, _) as def) :: defs->
       decr depth; push_def def; scan defs
    | def :: defs ->
       push_def def; scan defs
    | [] -> raise (Reporting.err_general l "$ifdef or $ifndef never ended by $endif")
  in
  scan defs

(* We want to provide warnings for e.g. a mispelled pragma rather than
   just silently ignoring them, so we have a list here of all
   recognised pragmas. *)
let all_pragmas =
  List.fold_left (fun set str -> StringSet.add str set) StringSet.empty
    [ "define";
      "include";
      "ifdef";
      "ifndef";
      "iftarget";
      "else";
      "endif";
      "option";
      "optimize";
      "latex";
      "property";
      "counterexample";
      "suppress_warnings";
      "include_start";
      "include_end";
      "sail_internal";
      "target_set";
      "non_exec"
    ]

let wrap_include l file = function
  | [] -> []
  | defs ->
     [Parse_ast.DEF_pragma ("include_start", file, l)]
     @ defs
     @ [Parse_ast.DEF_pragma ("include_end", file, l)]
 
let rec preprocess target opts = function
  | [] -> []
  | Parse_ast.DEF_pragma ("define", symbol, _) :: defs ->
     symbols := StringSet.add symbol !symbols;
     preprocess target opts defs

  | (Parse_ast.DEF_pragma ("option", command, l) as opt_pragma) :: defs ->
     begin
       try
         let args = Str.split (Str.regexp " +") command in
         Arg.parse_argv ~current:(ref 0) (Array.of_list ("sail" :: args)) opts (fun _ -> ()) "";
       with
       | Arg.Bad message | Arg.Help message -> raise (Reporting.err_general l message)
     end;
     opt_pragma :: preprocess target opts defs

  | Parse_ast.DEF_pragma ("ifndef", symbol, l) :: defs ->
     let then_defs, else_defs, defs = cond_pragma l defs in
     if not (StringSet.mem symbol !symbols) then
       preprocess target opts (then_defs @ defs)
     else
       preprocess target opts (else_defs @ defs)

  | Parse_ast.DEF_pragma ("ifdef", symbol, l) :: defs ->
     let then_defs, else_defs, defs = cond_pragma l defs in
     if StringSet.mem symbol !symbols then
       preprocess target opts (then_defs @ defs)
     else
       preprocess target opts (else_defs @ defs)

  | Parse_ast.DEF_pragma ("iftarget", t, l) :: defs ->
     let then_defs, else_defs, defs = cond_pragma l defs in
     begin match target with
     | Some target when target = t ->
        preprocess (Some target) opts (then_defs @ defs)
     | _ ->
        preprocess target opts (else_defs @ defs)
     end
       
  | Parse_ast.DEF_pragma ("include", file, l) :: defs ->
     let len = String.length file in
     if len = 0 then
       (Reporting.warn "" l "Skipping bad $include. No file argument."; preprocess target opts defs)
     else if file.[0] = '"' && file.[len - 1] = '"' then
       let relative = match l with
         | Parse_ast.Range (pos, _) -> Filename.dirname (Lexing.(pos.pos_fname))
         | _ -> failwith "Couldn't figure out relative path for $include. This really shouldn't ever happen."
       in
       let file = String.sub file 1 (len - 2) in
       let include_file = Filename.concat relative file in
       let include_defs = Initial_check.parse_file ~loc:l (Filename.concat relative file) |> snd |> preprocess target opts in
       wrap_include l include_file include_defs @ preprocess target opts defs
     else if file.[0] = '<' && file.[len - 1] = '>' then
       let file = String.sub file 1 (len - 2) in
       let sail_dir = Reporting.get_sail_dir () in
       let file = Filename.concat sail_dir ("lib/" ^ file) in
       let include_defs = Initial_check.parse_file ~loc:l file |> snd |> preprocess target opts in
       wrap_include l file include_defs @ preprocess target opts defs
     else
       let help = "Make sure the filename is surrounded by quotes or angle brackets" in
       (Reporting.warn "" l ("Skipping bad $include " ^ file ^ ". " ^ help); preprocess target opts defs)

  | Parse_ast.DEF_pragma ("suppress_warnings", _, l) :: defs ->
     begin match Reporting.simp_loc l with
     | None -> () (* This shouldn't happen, but if it does just continue *)
     | Some (p, _) -> Reporting.suppress_warnings_for_file p.pos_fname
     end;
     preprocess target opts defs

  (* Filter file_start and file_end out of the AST so when we
     round-trip files through the compiler we don't end up with
     incorrect start/end annotations *)
  | (Parse_ast.DEF_pragma ("file_start", _, _) | Parse_ast.DEF_pragma ("file_end", _, _)) :: defs ->
     preprocess target opts defs
 
  | Parse_ast.DEF_pragma (p, arg, l) :: defs ->
     if not (StringSet.mem p all_pragmas) then
       Reporting.warn "" l ("Unrecognised directive: " ^ p);
     Parse_ast.DEF_pragma (p, arg, l) :: preprocess target opts defs

  | Parse_ast.DEF_outcome (outcome_spec, inner_defs) :: defs ->
     Parse_ast.DEF_outcome (outcome_spec, preprocess target opts inner_defs) :: preprocess target opts defs
     
  | (Parse_ast.DEF_default (Parse_ast.DT_aux (Parse_ast.DT_order (_, Parse_ast.ATyp_aux (atyp, _)), _)) as def) :: defs ->
     begin match atyp with
     | Parse_ast.ATyp_inc -> symbols := StringSet.add "_DEFAULT_INC" !symbols; def :: preprocess target opts defs
     | Parse_ast.ATyp_dec -> symbols := StringSet.add "_DEFAULT_DEC" !symbols; def :: preprocess target opts defs
     | _ -> def :: preprocess target opts defs
     end

  | def :: defs -> def :: preprocess target opts defs
