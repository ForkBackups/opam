(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved.This file is distributed under the terms of the   *)
(*  GNU Lesser General Public License version 3.0 with linking            *)
(*  exception.                                                            *)
(*                                                                        *)
(*  OPAM is distributed in the hope that it will be useful, but WITHOUT   *)
(*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY    *)
(*  or FITNESS FOR A PARTICULAR PURPOSE.See the GNU General Public        *)
(*  License for more details.                                             *)
(*                                                                        *)
(**************************************************************************)

let log fmt = OpamConsole.log "CONFIG" fmt
let slog = OpamConsole.slog

open OpamTypes
(* open OpamState.Types *)

let help t =
  OpamConsole.msg "# Global OPAM configuration variables\n\n";
  let global = OpamState.global_config t in
  List.iter (fun var ->
      OpamConsole.msg "%-20s %s\n"
        (OpamVariable.to_string var)
        (match OpamFile.Dot_config.variable global var with
         | Some c -> OpamVariable.string_of_variable_contents c
         | None -> "")
    )
    (OpamFile.Dot_config.variables global);
  OpamConsole.msg "\n# Global variables from the environment\n\n";
  List.iter (fun (varname, doc) ->
      let var = OpamVariable.of_string varname in
      OpamConsole.msg "%-20s %-20s # %s\n"
        varname
        (OpamFilter.ident_string (OpamState.filter_env t) ~default:""
           ([],var,None))
        doc)
    OpamState.global_variable_names;
  OpamConsole.msg "\n# Package variables ('opam config list PKG' to show)\n\n";
  List.iter (fun (var, doc) ->
      OpamConsole.msg "PKG:%-37s # %s\n" var doc)
    OpamState.package_variable_names

(* List all the available variables *)
let list ns =
  log "config-list";
  let t = OpamState.load_state "config-list"
      OpamStateConfig.(!r.current_switch) in
  if ns = [] then help t else
  let list_vars name =
    if OpamPackage.Name.to_string name = "-" then
      let conf = OpamState.global_config t in
      List.map (fun (v,c) ->
          OpamVariable.Full.global v,
          OpamVariable.string_of_variable_contents c,
          "")
        (OpamFile.Dot_config.bindings conf)
    else
    try
      let nv = OpamState.get_package t name in
      let opam = OpamState.opam t nv in
      let env = OpamState.filter_env ~opam t in
      let conf = OpamState.dot_config t name in
      let pkg_vars =
        OpamStd.List.filter_map (fun (vname, desc) ->
            let v = OpamVariable.(Full.create name (of_string vname)) in
            try
              let c = OpamFilter.ident_string env (OpamFilter.ident_of_var v) in
              Some (v, c, desc)
            with Failure _ -> None)
          OpamState.package_variable_names
      in
      let feature_vars =
        List.map (fun (v, desc, filt) ->
            let v = OpamVariable.Full.create name v in
            v, OpamFilter.eval_to_string ~default:"#undefined" env filt, desc
          )
          (OpamFile.OPAM.features opam)
      in
      let conf_vars =
        List.map (fun (v,c) ->
            OpamVariable.Full.create name v,
            OpamVariable.string_of_variable_contents c,
            "")
          (OpamFile.Dot_config.bindings conf)
      in
      pkg_vars @ feature_vars @ conf_vars
    with Not_found -> []
  in
  let vars = List.flatten (List.map list_vars ns) in
  List.iter (fun (variable, value, descr) ->
      OpamConsole.msg "%-20s %-40s %s\n"
        (OpamVariable.Full.to_string variable)
        value
        (if descr <> "" then "# "^descr else "")
    ) vars

let print_env env =
  List.iter (fun (k,v) ->
    OpamConsole.msg "%s=%S; export %s;\n" k v k;
  ) env

let print_csh_env env =
  List.iter (fun (k,v) ->
    OpamConsole.msg "setenv %s %S;\n" k v;
  ) env

let print_sexp_env env =
  OpamConsole.msg "(\n";
  List.iter (fun (k,v) ->
    OpamConsole.msg "  (%S %S)\n" k v;
  ) env;
  OpamConsole.msg ")\n"

let print_fish_env env =
  List.iter (fun (k,v) ->
      match k with
      | "PATH" | "MANPATH" | "CDPATH" ->
        (* This function assumes that `v` does not include any variable expansions
         * and that the directory names are written in full. See the opamState.ml for details *)
        let v = OpamStd.String.split_delim v ':' in
        OpamConsole.msg "set -gx %s %s;\n" k
          (OpamStd.List.concat_map " " (Printf.sprintf "%S") v)
      | _ ->
        OpamConsole.msg "set -gx %s %S;\n" k v
    ) env

let env ~csh ~sexp ~fish ~inplace_path =
  log "config-env";
  let t = OpamState.load_env_state "config-env"
      OpamStateConfig.(!r.current_switch) in
  let env = OpamState.get_opam_env ~force_path:(not inplace_path) t in
  if sexp then
    print_sexp_env env
  else if csh then
    print_csh_env env
  else if fish then
    print_fish_env env
  else
    print_env env

let subst fs =
  log "config-substitute";
  let t = OpamState.load_state "config-substitute"
      OpamStateConfig.(!r.current_switch) in
  List.iter
    (OpamFilter.expand_interpolations_in_file (OpamState.filter_env t))
    fs

let quick_lookup v =
  if OpamVariable.Full.is_global v then (
    let var = OpamVariable.Full.variable v in
    let root = OpamStateConfig.(!r.root_dir) in
    let switch = OpamStateConfig.(!r.current_switch) in
    let config = OpamPath.Switch.global_config root switch in
    let config = OpamFile.Dot_config.read config in
    match OpamState.get_env_var v with
    | Some _ as c -> c
    | None ->
      if OpamVariable.to_string var = "switch" then
        Some (S (OpamSwitch.to_string switch))
      else
        OpamFile.Dot_config.variable config var
  ) else
    None

let variable v =
  log "config-variable";
  let contents =
    match quick_lookup v with
    | Some c -> c
    | None   ->
      let t = OpamState.load_state "config-variable"
          OpamStateConfig.(!r.current_switch) in
      OpamFilter.ident_value (OpamState.filter_env t) ~default:(S "#undefined")
        (OpamFilter.ident_of_var v)
  in
  OpamConsole.msg "%s\n" (OpamVariable.string_of_variable_contents contents)

let setup user global =
  log "config-setup";
  let t = OpamState.load_state "config-setup"
      OpamStateConfig.(!r.current_switch) in
  OpamState.update_setup t user global

let setup_list shell dot_profile =
  log "config-setup-list";
  let t = OpamState.load_state "config-setup-list"
      OpamStateConfig.(!r.current_switch) in
  OpamState.display_setup t shell dot_profile

let exec ~inplace_path command =
  log "config-exec command=%a" (slog (String.concat " ")) command;
  let t = OpamState.load_state "config-exec"
      OpamStateConfig.(!r.current_switch) in
  let cmd, args =
    match command with
    | []        -> OpamSystem.internal_error "Empty command"
    | h::_ as l -> h, Array.of_list l in
  let env =
    let env = OpamState.get_full_env ~force_path:(not inplace_path) t in
    let env = List.rev_map (fun (k,v) -> k^"="^v) env in
    Array.of_list env in
  raise (OpamStd.Sys.Exec (cmd, args, env))
