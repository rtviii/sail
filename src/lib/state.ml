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

module Big_int = Nat_big_num

open Initial_check
open Type_check
open Ast
open Ast_defs
open Ast_util
open PPrint
open Pretty_print_common
open Pretty_print_sail

let opt_type_grouped_regstate = ref false

let is_defined defs name = IdSet.mem (mk_id name) (ids_of_defs defs)

let has_default_order defs =
  List.exists (function DEF_default (DT_aux (DT_order _, _)) -> true | _ -> false) defs

let find_registers defs =
  List.fold_left
    (fun acc def ->
      match def with
      | DEF_reg_dec (DEC_aux(DEC_reg (typ, id, _), (_, tannot))) ->
         let env = match destruct_tannot tannot with
           | Some (env, _) -> env
           | _ -> Env.empty
         in
         (Env.expand_synonyms env typ, id) :: acc
      | _ -> acc
    ) [] defs

let generate_register_id_enum = function
  | [] -> ["type register_id = unit"]
  | registers ->
     let reg (typ, id) = string_of_id id in
     ["type register_id = " ^ String.concat " | " (List.map reg registers)]

let rec id_of_regtyp builtins mwords (Typ_aux (t, l) as typ) = match t with
  | Typ_id id -> id
  | Typ_app (id, args) ->
     let name_arg (A_aux (targ, _)) = match targ with
       | A_typ targ -> string_of_id (id_of_regtyp builtins mwords targ)
       | A_nexp nexp when is_nexp_constant (nexp_simp nexp) ->
          string_of_nexp (nexp_simp nexp)
       | A_order (Ord_aux (Ord_inc, _)) -> "inc"
       | A_order (Ord_aux (Ord_dec, _)) -> "dec"
       | _ ->
          raise (Reporting.err_typ l "Unsupported register type")
     in
     if IdSet.mem id builtins && not (mwords && is_bitvector_typ typ) then id else
     append_id id (String.concat "_" ("" :: List.map name_arg args))
  | _ -> raise (Reporting.err_typ l "Unsupported register type")

let regstate_field typ = append_id (id_of_regtyp IdSet.empty false typ) "_reg"

let generate_regstate registers =
  let regstate_def =
    if registers = [] then
      TD_abbrev (mk_id "regstate", mk_typquant [], mk_typ_arg (A_typ unit_typ))
    else
      let fields =
        if !opt_type_grouped_regstate then
          List.map
            (fun (typ, id) ->
                 (function_typ [string_typ] typ,
                  regstate_field typ))
            registers
          |> List.sort_uniq (fun (typ1, id1) (typ2, id2) -> Id.compare id1 id2)
        else registers
      in
      TD_record (mk_id "regstate", mk_typquant [], fields, false)
  in
  [DEF_type (TD_aux (regstate_def, (Unknown, ())))]

let generate_initial_regstate defs =
  let registers = find_registers defs in
  if registers = [] then [] else
  try
    (* Recursively choose a default value for every type in the spec.
       vals, constructed below, maps user-defined types to default values. *)
    let rec lookup_init_val vals (Typ_aux (typ_aux, _)) =
      match typ_aux with
      | Typ_id id ->
         if string_of_id id = "bool" then "false" else
         if string_of_id id = "bit" then "bitzero" else
         if string_of_id id = "int" then "0" else
         if string_of_id id = "nat" then "0" else
         if string_of_id id = "real" then "0" else
         if string_of_id id = "string" then "\"\"" else
         if string_of_id id = "unit" then "()" else
         Bindings.find id vals []
      | Typ_app (id, _) when string_of_id id = "list" -> "[||]"
      | Typ_app (id, [A_aux (A_nexp nexp, _)]) when string_of_id id = "atom" ->
         string_of_nexp nexp
      | Typ_app (id, [A_aux (A_nexp nexp, _); _]) when string_of_id id = "range" ->
         string_of_nexp nexp
      | Typ_app (id, [A_aux (A_nexp (Nexp_aux (Nexp_constant len, _)), _); _])
        when string_of_id id = "bitvector" ->
         (* Output a literal binary zero value if this is a bitvector
            and the environment has a default indexing order (required
            by the typechecker for binary and hex literals) *)
         let literal_bitvec = has_default_order defs in
         let init_elem = if literal_bitvec then "0" else lookup_init_val vals bit_typ in
         let rec elems len =
           if (Nat_big_num.less_equal len Nat_big_num.zero) then [] else
           init_elem :: elems (Nat_big_num.pred len)
         in
         if literal_bitvec then
           "0b" ^ (String.concat "" (elems len))
         else
           "[" ^ (String.concat ", " (elems len)) ^ "]"
      | Typ_app (id, [A_aux (A_nexp (Nexp_aux (Nexp_constant len, _)), _); _ ;
                      A_aux (A_typ etyp, _)])
        when string_of_id id = "vector" ->
         (* Output a list of initial values of the vector elements. *)
         let init_elem = lookup_init_val vals etyp in
         let rec elems len =
           if (Nat_big_num.less_equal len Nat_big_num.zero) then [] else
           init_elem :: elems (Nat_big_num.pred len)
         in
         "[" ^ (String.concat ", " (elems len)) ^ "]"
      | Typ_app (id, args) -> Bindings.find id vals args
      | Typ_tup typs ->
         "(" ^ (String.concat ", " (List.map (lookup_init_val vals) typs)) ^ ")"
      | Typ_exist (_, _, typ) -> lookup_init_val vals typ
      | _ -> raise Not_found
    in
    let typ_subst_quant_item typ (QI_aux (qi, _)) arg = match qi with
      | QI_id (KOpt_aux (KOpt_kind (_, kid), _)) ->
         typ_subst kid arg typ
      | _ -> typ
    in
    let typ_subst_typquant tq args typ =
      List.fold_left2 typ_subst_quant_item typ (quant_items tq) args
    in
    let add_typ_init_val (defs', vals) = function
      | TD_enum (id, id1 :: _, _) ->
         (* Choose the first value of an enumeration type as default *)
         (defs', Bindings.add id (fun _ -> string_of_id id1) vals)
      | TD_variant (id, tq, (Tu_aux (Tu_ty_id (typ1, id1), _)) :: _, _) ->
         (* Choose the first variant of a union type as default *)
         let init_val args =
           let typ1 = typ_subst_typquant tq args typ1 in
           string_of_id id1 ^ " (" ^ lookup_init_val vals typ1 ^ ")"
         in
         (defs', Bindings.add id init_val vals)
      | TD_abbrev (id, tq, A_aux (A_typ typ, _)) ->
         let init_val args = lookup_init_val vals (typ_subst_typquant tq args typ) in
         (defs', Bindings.add id init_val vals)
      | TD_record (id, tq, fields, _) ->
         let init_val args =
           let init_field (typ, id) =
             let typ = typ_subst_typquant tq args typ in
             string_of_id id ^ " = " ^ lookup_init_val vals typ
           in
           "struct { " ^ (String.concat ", " (List.map init_field fields)) ^ " }"
         in
         let def_name = "initial_" ^ string_of_id id in
         if quant_items tq = [] && not (is_defined defs def_name) then
           (defs' @ ["let " ^ def_name ^ " : " ^ string_of_id id ^ " = " ^ init_val []],
            Bindings.add id (fun _ -> def_name) vals)
         else (defs', Bindings.add id init_val vals)
      | TD_bitfield (id, typ, _) ->
         (defs', Bindings.add id (fun _ -> lookup_init_val vals typ) vals)
      | _ -> (defs', vals)
    in
    let (init_defs, init_vals) = List.fold_left (fun inits def -> match def with
      | DEF_type (TD_aux (td, _)) -> add_typ_init_val inits td
      | _ -> inits) ([], Bindings.empty) defs
    in
    let init_reg (typ, id) = string_of_id id ^ " = " ^ lookup_init_val init_vals typ in
    List.map (defs_of_string __POS__)
      (init_defs @
       ["let initial_regstate : regstate = struct { " ^
        (String.concat ", " (List.map init_reg registers)) ^
        " }"])
  with
  | _ -> [] (* Do not generate an initial register state if anything goes wrong *)

let regval_constr_id = id_of_regtyp (IdSet.of_list (List.map mk_id ["bool"; "int"; "real"; "string"; "vector"; "bitvector"; "list"; "option"]))

let register_base_types mwords typs =
  let rec add_base_typs typs (Typ_aux (t, _) as typ) =
    let builtins = IdSet.of_list (List.map mk_id ["bool"; "atom_bool"; "atom"; "int"; "real"; "string"; "vector"; "list"; "option"]) in
    match t with
      | Typ_app (id, args)
        when IdSet.mem id builtins && not (mwords && is_bitvector_typ typ) ->
         let add_typ_arg base_typs (A_aux (targ, _)) =
           match targ with
             | A_typ typ -> add_base_typs base_typs typ
             | _ -> base_typs
         in
         List.fold_left add_typ_arg typs args
      | Typ_id id when IdSet.mem id builtins -> typs
      | _ -> Bindings.add (regval_constr_id mwords typ) typ typs
  in
  List.fold_left add_base_typs Bindings.empty (bit_typ :: typs)

let generate_regval_typ typs =
  let constr (constr_id, typ) =
    Printf.sprintf "Regval_%s : %s" (string_of_id constr_id) (to_string (doc_typ typ)) in
  let builtins =
    "Regval_vector : list(register_value), " ^
    "Regval_list : list(register_value), " ^
    "Regval_option : option(register_value), " ^
    "Regval_bool : bool, " ^
    "Regval_int : int, " ^
    "Regval_real : real, " ^
    "Regval_string : string"
  in
  [defs_of_string __POS__
    ("union register_value = { " ^
     (String.concat ", " (builtins :: List.map constr (Bindings.bindings typs))) ^
     " }")]

let regval_class_typs_lem = [("bool", "bool"); ("int", "integer"); ("real", "real"); ("string", "string")]

let regval_instance_lem =
  let conv_def (name, typ) =
    [ "val " ^ name ^ "_of_register_value : register_value -> maybe " ^ typ;
      "let " ^ name ^ "_of_register_value rv = match rv with Regval_" ^ name ^ " v -> Just v | _ -> Nothing end";
      "val register_value_of_" ^ name ^ " : " ^ typ ^ " -> register_value";
      "let register_value_of_" ^ name ^ " v = Regval_" ^ name ^ " v" ]
  in
  let conv_inst (name, typ) =
    [ "let " ^ name ^ "_of_regval = " ^ name ^ "_of_register_value";
      "let regval_of_" ^ name ^ " = register_value_of_" ^ name ]
  in
  separate_map hardline string
    (List.concat (List.map conv_def regval_class_typs_lem)
    @ [""; "instance (Register_Value register_value)"]
    @ List.concat (List.map conv_inst regval_class_typs_lem)
    @ ["end"])

let add_regval_conv id typ defs =
  let id = string_of_id id in
  let typ_str = to_string (doc_typ typ) in
  (* Create a function that converts from regval to the target type. *)
  let from_name = id ^ "_of_regval" in
  let from_val = Printf.sprintf "val %s : register_value -> option(%s)" from_name typ_str in
  let from_function = String.concat "\n" [
    Printf.sprintf "function %s Regval_%s(v) = Some(v)" from_name id;
    Printf.sprintf "and %s _ = None()" from_name
    ] in
  let from_defs = if is_defined defs from_name then [] else [from_val; from_function] in
  (* Create a function that converts from target type to regval. *)
  let to_name = "regval_of_" ^ id in
  let to_val = Printf.sprintf "val %s : %s -> register_value" to_name typ_str in
  let to_function = Printf.sprintf "function %s v = Regval_%s(v)" to_name id in
  let to_defs = if is_defined defs to_name then [] else [to_val; to_function] in
  let cdefs = List.concat (List.map (defs_of_string __POS__) (from_defs @ to_defs)) in
  defs @ cdefs

let rec regval_convs mwords wrap_fun (Typ_aux (t, _) as typ) = match t with
  | Typ_app _ when (is_vector_typ typ || is_bitvector_typ typ) && not (mwords && is_bitvector_typ typ) ->
     let size, ord, etyp = vector_typ_args_of typ in
     let etyp_of, of_etyp = regval_convs mwords wrap_fun etyp in
     "vector_of_regval " ^ wrap_fun etyp_of,
     "regval_of_vector " ^ wrap_fun of_etyp
  | Typ_app (id, [A_aux (A_typ etyp, _)])
    when string_of_id id = "list" ->
     let etyp_of, of_etyp = regval_convs mwords wrap_fun etyp in
     "list_of_regval " ^ wrap_fun etyp_of,
     "regval_of_list " ^ wrap_fun of_etyp
  | Typ_app (id, [A_aux (A_typ etyp, _)])
    when string_of_id id = "option" ->
     let etyp_of, of_etyp = regval_convs mwords wrap_fun etyp in
     "option_of_regval " ^ wrap_fun etyp_of,
     "regval_of_option " ^ wrap_fun of_etyp
  | _ ->
     let id = string_of_id (regval_constr_id mwords typ) in
     if List.mem id (List.map fst regval_class_typs_lem)
     then id ^ "_of_register_value", "register_value_of_" ^ id
     else id ^ "_of_regval", "regval_of_" ^ id

let regval_convs_lem mwords = regval_convs mwords (fun conv -> "(fun v -> " ^ conv ^ " v)")
let regval_convs_isa mwords = regval_convs mwords (fun conv -> "(\\<lambda>v. " ^ conv ^ " v)")

let register_refs_lem mwords pp_tannot registers =
  let generic_convs =
    separate_map hardline string [
      "val vector_of_regval : forall 'a. (register_value -> maybe 'a) -> register_value -> maybe (list 'a)";
      "let vector_of_regval of_regval rv = match rv with";
      "  | Regval_vector v -> just_list (List.map of_regval v)";
      "  | _ -> Nothing";
      "end";
      "";
      "val regval_of_vector : forall 'a. ('a -> register_value) -> list 'a -> register_value";
      "let regval_of_vector regval_of xs = Regval_vector (List.map regval_of xs)";
      "";
      "val list_of_regval : forall 'a. (register_value -> maybe 'a) -> register_value -> maybe (list 'a)";
      "let list_of_regval of_regval rv = match rv with";
      "  | Regval_list v -> just_list (List.map of_regval v)";
      "  | _ -> Nothing";
      "end";
      "";
      "val regval_of_list : forall 'a. ('a -> register_value) -> list 'a -> register_value";
      "let regval_of_list regval_of xs = Regval_list (List.map regval_of xs)";
      "";
      "val option_of_regval : forall 'a. (register_value -> maybe 'a) -> register_value -> maybe (maybe 'a)";
      "let option_of_regval of_regval rv = match rv with";
      "  | Regval_option v -> Just (Maybe.bind v of_regval)";
      "  | _ -> Nothing";
      "end";
      "";
      "val regval_of_option : forall 'a. ('a -> register_value) -> maybe 'a -> register_value";
      "let regval_of_option regval_of v = Regval_option (Maybe.map regval_of v)";
      "";
      ""
    ]
  in
  let register_ref (typ, id) =
    let idd = string (string_of_id id) in
    let (read_from, write_to) =
      if !opt_type_grouped_regstate then
        let field_idd = string (string_of_id (regstate_field typ)) in
        (field_idd ^^ space ^^ dquotes idd,
         doc_op equals field_idd (string "(fun reg -> if reg = \"" ^^ idd ^^ string "\" then v else s." ^^ field_idd ^^ string " reg)"))
      else
        (idd, doc_op equals idd (string "v"))
    in
    (* let field = if prefix_recordtype then string "regstate_" ^^ idd else idd in *)
    let of_regval, regval_of = regval_convs_lem mwords typ in
    let tannot = pp_tannot typ in
    concat [string "let "; idd; string "_ref "; tannot; string " = <|"; hardline;
      string "  name = \""; idd; string "\";"; hardline;
      string "  read_from = (fun s -> s."; read_from; string ");"; hardline;
      string "  write_to = (fun v s -> (<| s with "; write_to; string " |>));"; hardline;
      string "  of_regval = (fun v -> "; string of_regval; string " v);"; hardline;
      string "  regval_of = (fun v -> "; string regval_of; string " v) |>"; hardline]
  in
  let refs = separate_map hardline register_ref registers in
  let mk_reg_assoc (_, id) =
    let idd = string_of_id id in
    let qidd = "\"" ^ idd ^ "\"" in
    string ("    (" ^ qidd ^ ", register_ops_of " ^ idd ^ "_ref)")
  in
  let reg_assocs = separate hardline [
    string "val registers : list (string * register_ops regstate register_value)";
    string "let registers = [";
    separate (string ";" ^^ hardline) (List.map mk_reg_assoc registers);
    string "  ]"] ^^ hardline
  in
  let getters_setters =
    string "let register_accessors = mk_accessors (fun nm -> List.lookup nm registers)" ^^
    hardline ^^ hardline ^^
    string "val get_regval : string -> regstate -> maybe register_value" ^^ hardline ^^
    string "let get_regval = fst register_accessors" ^^ hardline ^^ hardline ^^
    string "val set_regval : string -> register_value -> regstate -> maybe regstate" ^^ hardline ^^
    string "let set_regval = snd register_accessors" ^^ hardline ^^ hardline
    (* string "let liftS s = liftState register_accessors s" ^^ hardline *)
  in
  separate hardline [generic_convs; refs; reg_assocs; getters_setters]

(* TODO Generate well-typedness predicate for register states (and events),
   asserting that all lists representing non-bit-vectors have the right length. *)

let generate_isa_lemmas mwords defs =
  let rec drop_while f = function
    | x :: xs when f x -> drop_while f xs
    | xs -> xs
  in
  let remove_leading_underscores str =
    String.concat "_" (drop_while (fun s -> s = "") (Util.split_on_char '_' str))
  in
  let remove_trailing_underscores str =
    Util.split_on_char '_' str |> List.rev |>
    drop_while (fun s -> s = "") |> List.rev |>
    String.concat "_"
  in
  let remove_underscores str = remove_leading_underscores (remove_trailing_underscores str) in
  let registers = find_registers defs in
  let regtyp_ids =
    register_base_types mwords (List.map fst registers)
    |> Bindings.bindings |> List.map fst
  in
  let regval_class_typ_ids = List.map (fun (t, _) -> mk_id t) regval_class_typs_lem in
  let register_defs =
    let reg_id id = remove_leading_underscores (string_of_id id) in
    hang 2 (flow_map (break 1) string
      (["lemmas register_defs"; "="; "get_regval_unfold"; "set_regval_unfold"] @
      (List.map (fun (typ, id) -> reg_id id ^ "_ref_def") registers)))
  in
  let conv_lemma typ_id =
    let typ_id = remove_trailing_underscores (string_of_id typ_id) in
    let typ_id' = remove_leading_underscores typ_id in
    let (of_rv, rv_of) =
      if List.mem typ_id (List.map fst regval_class_typs_lem)
      then (typ_id' ^ "_of_register_value", "register_value_of_" ^ typ_id)
      else (typ_id' ^ "_of_regval", "regval_of_" ^ typ_id)
    in
    string ("lemma " ^ of_rv ^ "_eq_Some_iff[simp]:") ^^ hardline ^^
    string ("  \"" ^ of_rv ^ " rv = Some v \\<longleftrightarrow> rv = Regval_" ^ typ_id ^ " v\"") ^^ hardline ^^
    string ("  by (cases rv; auto)") ^^ hardline ^^
    hardline ^^
    string ("declare " ^ rv_of ^ "_def[simp]") ^^ hardline ^^
    hardline ^^
    string ("lemma regval_" ^ typ_id ^ "[simp]:") ^^ hardline ^^
    string ("  \"" ^ of_rv ^ " (" ^ rv_of ^ " v) = Some v\"") ^^ hardline ^^
    string ("  by auto")
  in
  let register_lemmas (typ, id) =
    let id = remove_leading_underscores (string_of_id id) in
    separate_map hardline string [
      "lemma liftS_read_reg_" ^ id ^ "[liftState_simp]:";
      "  \"\\<lbrakk>read_reg " ^ id ^ "_ref\\<rbrakk>\\<^sub>S = read_regS " ^ id ^ "_ref\"";
      "  by (intro liftState_read_reg) (auto simp: register_defs)";
      "";
      "lemma liftS_write_reg_" ^ id ^ "[liftState_simp]:";
      "  \"\\<lbrakk>write_reg " ^ id ^ "_ref v\\<rbrakk>\\<^sub>S = write_regS " ^ id ^ "_ref v\"";
      "  by (intro liftState_write_reg) (auto simp: register_defs)"
    ]
  in
  let registers_eqs = separate hardline (List.map string [
    "lemma registers_distinct:";
    "  \"distinct (map fst registers)\"";
    "  unfolding registers_def list.simps fst_conv";
    "  by (distinct_string; simp)";
    "";
    "lemma registers_eqs_setup:";
    "  \"!x : set registers. map_of registers (fst x) = Some (snd x)\"";
    "  using registers_distinct";
    "  by simp";
    "";
    "lemmas map_of_registers_eqs[simp] =";
    "    registers_eqs_setup[simplified arg_cong[where f=set, OF registers_def]";
    "        list.simps ball_simps fst_conv snd_conv]";
    "";
    "lemmas get_regval_unfold = get_regval_def[THEN fun_cong,";
    "    unfolded register_accessors_def mk_accessors_def fst_conv snd_conv]";
    "lemmas set_regval_unfold = set_regval_def[THEN fun_cong,";
    "    unfolded register_accessors_def mk_accessors_def fst_conv snd_conv]";
  ])
  in
  let module StringMap = Map.Make(String) in
  let field_id typ = remove_leading_underscores (string_of_id (id_of_regtyp IdSet.empty false typ)) in
  let field_id_stripped typ = remove_trailing_underscores (field_id typ) in
  let set_regval_type_cases =
    let add_reg_case cases (typ, id) =
      let of_regval = remove_underscores (fst (regval_convs_isa mwords typ)) in
      let case =
        "(" ^ field_id_stripped typ ^ ") v where " ^
        "\"" ^ of_regval ^ " rv = Some v\" and " ^
        "\"s' = s\\<lparr>" ^ field_id typ ^ "_reg := (" ^ field_id typ ^ "_reg s)(r := v)\\<rparr>\""
      in
      StringMap.add (field_id typ) case cases
    in
    let cases = List.fold_left add_reg_case StringMap.empty registers |> StringMap.bindings |> List.map snd in
    let prove_case (typ, id) = "    subgoal using " ^ field_id_stripped typ ^ " by (auto simp: register_defs fun_upd_def)" in
    if List.length cases > 0 && !opt_type_grouped_regstate then
      string "lemma set_regval_Some_type_cases:" ^^ hardline ^^
      string "  assumes \"set_regval r rv s = Some s'\"" ^^ hardline ^^
      string "  obtains " ^^ separate_map (hardline ^^ string "  | ") string cases ^^ hardline ^^
      string "proof -" ^^ hardline ^^
      string "  from assms show ?thesis" ^^ hardline ^^
      string "    unfolding set_regval_unfold registers_def" ^^ hardline ^^
      string "    apply (elim option_bind_SomeE map_of_Cons_SomeE)" ^^ hardline ^^
      separate_map hardline string (List.map prove_case registers) ^^ hardline ^^
      string "    by auto" ^^ hardline ^^
      string "qed"
    else string ""
  in
  let get_regval_type_cases =
    let add_reg_case cases (typ, id) =
      let regval_of = remove_underscores (snd (regval_convs_isa mwords typ)) in
      let case = "(" ^ field_id_stripped typ ^ ") \"get_regval r = (\\<lambda>s. Some (" ^ regval_of ^ " (" ^ field_id typ ^ "_reg s r)))\"" in
      StringMap.add (field_id typ) case cases
    in
    let cases = List.fold_left add_reg_case StringMap.empty registers in
    let fail_case = "(None) \"get_regval r = (\\<lambda>s. None)\"" in
    let cases = (StringMap.bindings cases |> List.map snd) @ [fail_case] in
    let prove_case (typ, id) = "    subgoal using " ^ field_id_stripped typ ^ " by (auto simp: register_defs)" in
    if !opt_type_grouped_regstate then
      string "lemma get_regval_type_cases:" ^^ hardline ^^
      string "  fixes r :: string" ^^ hardline ^^
      string "  obtains " ^^ separate_map (hardline ^^ string "  | ") string cases ^^ hardline ^^
      string "proof (cases \"map_of registers r\")" ^^ hardline ^^
      string "  case (Some ops)" ^^ hardline ^^
      string "  then show ?thesis" ^^ hardline ^^
      string "    unfolding registers_def" ^^ hardline ^^
      string "    apply (elim map_of_Cons_SomeE)" ^^ hardline ^^
      separate_map hardline string (List.map prove_case registers) ^^ hardline ^^
      string "    by auto" ^^ hardline ^^
      string "qed (auto simp: get_regval_unfold)"
    else string ""
  in
  registers_eqs ^^ hardline ^^ hardline ^^
  string "abbreviation liftS (\"\\<lbrakk>_\\<rbrakk>\\<^sub>S\") where \"liftS \\<equiv> liftState (get_regval, set_regval)\"" ^^
  hardline ^^ hardline ^^
  register_defs ^^
  hardline ^^ hardline ^^
  separate_map (hardline ^^ hardline) conv_lemma (regval_class_typ_ids @ regtyp_ids) ^^
  hardline ^^ hardline ^^
  separate_map hardline string [
    "lemma vector_of_rv_rv_of_vector[simp]:";
    "  assumes \"\\<And>v. of_rv (rv_of v) = Some v\"";
    "  shows \"vector_of_regval of_rv (regval_of_vector rv_of v) = Some v\"";
    "proof -";
    "  from assms have \"of_rv \\<circ> rv_of = Some\" by auto";
    "  then show ?thesis by (auto simp: regval_of_vector_def)";
    "qed";
    "";
    "lemma option_of_rv_rv_of_option[simp]:";
    "  assumes \"\\<And>v. of_rv (rv_of v) = Some v\"";
    "  shows \"option_of_regval of_rv (regval_of_option rv_of v) = Some v\"";
    "  using assms by (cases v) (auto simp: regval_of_option_def)";
    "";
    "lemma list_of_rv_rv_of_list[simp]:";
    "  assumes \"\\<And>v. of_rv (rv_of v) = Some v\"";
    "  shows \"list_of_regval of_rv (regval_of_list rv_of v) = Some v\"";
    "proof -";
    "  from assms have \"of_rv \\<circ> rv_of = Some\" by auto";
    "  with assms show ?thesis by (induction v) (auto simp: regval_of_list_def)";
    "qed"] ^^
  hardline ^^ hardline ^^
  separate_map (hardline ^^ hardline) register_lemmas registers ^^
  hardline ^^ hardline ^^
  set_regval_type_cases ^^
  hardline ^^ hardline ^^
  get_regval_type_cases

let rec regval_convs_coq (Typ_aux (t, _) as typ) = match t with
  | Typ_app _ when is_vector_typ typ && not (is_bitvector_typ typ) ->
     let size, ord, etyp = vector_typ_args_of typ in
     let size = string_of_nexp (nexp_simp size) in
     let etyp_of, of_etyp = regval_convs_coq etyp in
     "(fun v => vector_of_regval " ^ size ^ " " ^ etyp_of ^ " v)",
     "(fun v => regval_of_vector " ^ of_etyp ^ " v)"
  | Typ_app (id, [A_aux (A_typ etyp, _)])
    when string_of_id id = "list" ->
     let etyp_of, of_etyp = regval_convs_coq etyp in
     "(fun v => list_of_regval " ^ etyp_of ^ " v)",
     "(fun v => regval_of_list " ^ of_etyp ^ " v)"
  | Typ_app (id, [A_aux (A_typ etyp, _)])
    when string_of_id id = "option" ->
     let etyp_of, of_etyp = regval_convs_coq etyp in
     "(fun v => option_of_regval " ^ etyp_of ^ " v)",
     "(fun v => regval_of_option " ^ of_etyp ^ " v)"
  | _ ->
     let id = string_of_id (regval_constr_id true typ) in
     "(fun v => " ^ id ^ "_of_regval v)", "(fun v => regval_of_" ^ id ^ " v)"

let register_refs_coq doc_id registers =
  let generic_convs =
    separate_map hardline string [
      "Definition bool_of_regval (merge_var : register_value) : option bool :=";
      "  match merge_var with | Regval_bool v => Some v | _ => None end.";
      "";
      "Definition regval_of_bool (v : bool) : register_value := Regval_bool v.";
      "";
      "Definition int_of_regval (merge_var : register_value) : option Z :=";
      "  match merge_var with | Regval_int v => Some v | _ => None end.";
      "";
      "Definition regval_of_int (v : Z) : register_value := Regval_int v.";
      "";
      "Definition real_of_regval (merge_var : register_value) : option R :=";
      "  match merge_var with | Regval_real v => Some v | _ => None end.";
      "";
      "Definition regval_of_real (v : R) : register_value := Regval_real v.";
      "";
      "Definition string_of_regval (merge_var : register_value) : option string :=";
      "  match merge_var with | Regval_string v => Some v | _ => None end.";
      "";
      "Definition regval_of_string (v : string) : register_value := Regval_string v.";
      "";
      "Definition vector_of_regval {a} n (of_regval : register_value -> option a) (rv : register_value) : option (vec a n) := match rv with";
      "  | Regval_vector v => if n =? length_list v then map_bind (vec_of_list n) (just_list (List.map of_regval v)) else None";
      "  | _ => None";
      "end.";
      "";
      "Definition regval_of_vector {a size} (regval_of : a -> register_value) (xs : vec a size) : register_value := Regval_vector (List.map regval_of (list_of_vec xs)).";
      "";
      "Definition list_of_regval {a} (of_regval : register_value -> option a) (rv : register_value) : option (list a) := match rv with";
      "  | Regval_list v => just_list (List.map of_regval v)";
      "  | _ => None";
      "end.";
      "";
      "Definition regval_of_list {a} (regval_of : a -> register_value) (xs : list a) : register_value := Regval_list (List.map regval_of xs).";
      "";
      "Definition option_of_regval {a} (of_regval : register_value -> option a) (rv : register_value) : option (option a) := match rv with";
      "  | Regval_option v => option_map of_regval v";
      "  | _ => None";
      "end.";
      "";
      "Definition regval_of_option {a} (regval_of : a -> register_value) (v : option a) := Regval_option (option_map regval_of v).";
      "";
      ""
    ]
  in
  let register_ref (typ, id) =
    let idd = doc_id id in
    (* let field = if prefix_recordtype then string "regstate_" ^^ idd else idd in *)
    let of_regval, regval_of = regval_convs_coq typ in
    concat [string "Definition "; idd; string "_ref := {|"; hardline;
      string "  name := \""; idd; string "\";"; hardline;
      string "  read_from := (fun s => s.("; idd; string "));"; hardline;
      string "  write_to := (fun v s => ({[ s with "; idd; string " := v ]}));"; hardline;
      string "  of_regval := "; string of_regval; string ";"; hardline;
      string "  regval_of := "; string regval_of; string " |}."; hardline]
  in
  let refs = separate_map hardline register_ref registers in
  let get_set_reg (_, id) =
    let idd = doc_id id in
    concat [string "  if string_dec reg_name \""; idd; string "\" then Some ("; idd; string "_ref.(regval_of) ("; idd; string "_ref.(read_from) s)) else"],
    concat [string "  if string_dec reg_name \""; idd; string "\" then option_map (fun v => "; idd; string "_ref.(write_to) v s) ("; idd; string "_ref.(of_regval) v) else"]
  in
  let getters_setters =
    let getters, setters = List.split (List.map get_set_reg registers) in
    string "Local Open Scope string." ^^ hardline ^^
    string "Definition get_regval (reg_name : string) (s : regstate) : option register_value :=" ^^ hardline ^^
    separate hardline getters ^^ hardline ^^
    string "  None." ^^ hardline ^^ hardline ^^
    string "Definition set_regval (reg_name : string) (v : register_value) (s : regstate) : option regstate :=" ^^ hardline ^^
    separate hardline setters ^^ hardline ^^
    string "  None." ^^ hardline ^^ hardline ^^
    string "Definition register_accessors := (get_regval, set_regval)." ^^ hardline ^^ hardline
  in
  separate hardline [generic_convs; refs; getters_setters]

let generate_regstate_defs mwords defs =
  (* FIXME We currently don't want to generate undefined_type functions
     for register state and values.  For the Lem backend, this would require
     taking the dependencies of those functions into account when partitioning
     definitions into the different lem files, which we currently don't do. *)
  let gen_undef = !Initial_check.opt_undefined_gen in
  Initial_check.opt_undefined_gen := false;
  let registers = find_registers defs in
  let regtyps = register_base_types mwords (List.map fst registers) in
  let option_typ =
    if is_defined defs "option" then [] else
      [defs_of_string __POS__ "union option ('a : Type) = {None : unit, Some : 'a}"]
  in
  let regval_typ = if is_defined defs "register_value" then [] else generate_regval_typ regtyps in
  let regstate_typ = if is_defined defs "regstate" then [] else [generate_regstate registers] in
  let initregstate =
    (* Don't create initial regstate if it is already defined or if we generated
       a regstate record with registers grouped per type; the latter would
       require record fields storing functions, which is not supported in
       Sail. *)
    if is_defined defs "initial_regstate" || !opt_type_grouped_regstate then [] else
    generate_initial_regstate defs
  in
  let defs =
    option_typ @ regval_typ @ regstate_typ @ initregstate
    |> List.concat
    |> Bindings.fold add_regval_conv regtyps
  in
  Initial_check.opt_undefined_gen := gen_undef;
  defs

let add_regstate_defs mwords env ast =
  let reg_defs, env = Type_error.check_defs env (generate_regstate_defs mwords ast.defs) in
  env, append_ast_defs ast reg_defs
