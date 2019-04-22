module JSON = Yojson.Basic
module OPAM = OpamFile.OPAM
open Util

let getenv k =
	try Unix.getenv k
	with Not_found as e ->
		Printf.eprintf "Missing environment variable: %s\n" k;
		raise e

type env = {
	vars : Vars.env;
	spec : OpamFile.OPAM.t;
	files : string option;
	pkgname : string;
}

let destDir () = (getenv "out")
let libDestDir () = Filename.concat (destDir ()) "lib"

let unexpected_json desc j =
	failwith ("Unexpected " ^ desc ^ ": " ^ (JSON.to_string j))

let load_env () =
	let open Vars in
	let destDir = destDir () in
	let self_name = ref None in
	let self_version = ref None in
	let packages = ref StringMap.empty in

	let add_package name impl =
		debug " - package %s: %s\n" name (match impl with
			| Absent -> "absent"
			| Provided -> "provided"
			| Installed { path; version } ->
				Printf.sprintf "%s (%s)"
					(Option.to_string id path)
					(Option.to_string id version)
		);
		packages := StringMap.add name impl !packages
	in

	let spec = ref None in
	let files = ref None in
	(* let specfile = ref None in *)
	let json_str = getenv "opamEnv" in
	debug "Using opamEnv: %s\n" json_str;
	let json = JSON.from_string json_str in
	let () = match json with
		| `Assoc pairs -> begin
			pairs |> List.iter (function
					| "deps", `Assoc (attrs) -> begin
						debug "adding packages from opamEnv\n";
						attrs |> List.iter (fun (pkgname, value) ->
							match value with
								| `Null -> add_package pkgname Absent

									(* Bool is used for base packages, which have no corresponding path *)
								| `Bool b -> add_package pkgname (if b then Provided else Absent)

								| `Assoc attrs -> (
									let path = ref None in
									let version = ref None in
									attrs |> List.iter (fun (key, value) ->
										match (key, value) with
											| "path", `String value -> path := Some value
											| "version", `String value -> version := Some value
											| "version", `Null -> version := None
											| _, other -> unexpected_json ("deps." ^ pkgname) other
									);
									add_package pkgname (Installed {
										(* path is optional in the type, but by `invoke` time all paths
										 * should be defined *)
										path = Some (!path |> Option.or_failwith "missing `path` in deps");
										version = !version;
									})
								)

								| other -> unexpected_json "deps value" other
						)
					end
					| "deps", other -> unexpected_json "deps" other

					| "name", `String name -> self_name := Some name;
					| "name", other -> unexpected_json "name" other

					| "version", `String version -> self_version := Some version;
					| "version", other -> unexpected_json "version" other

					| "files", `String path -> files := Some path
					| "files", `Null -> ()
					| "files", other -> unexpected_json "files" other

					| "spec", `String path ->
							Printf.eprintf "Loading %s\n" path;
							spec := Some (Opam_metadata.load_opam path)
					| "spec", other -> unexpected_json "spec" other

					| other, _ -> failwith ("unexpected opamEnv key: " ^ other)
			)
		end
		| other -> unexpected_json "toplevel" other
	in
	let spec = (match !spec with Some s -> s | None -> failwith "missing `spec` in opamEnv") in
	let self = !self_name |> Option.or_failwith "self name not specified" in
	let self_impl = Vars.{
		path = Some destDir;
		version = Some (!self_version |> Option.or_failwith "self version not specified");
	} in

	{
		vars = Vars.({
			prefix = Some destDir;
			packages = !packages |> StringMap.add self (Installed self_impl);
			self = self;
			vars = Opam_metadata.init_variables ();
		});
		pkgname = self;
		files = !files;
		spec;
	}

let rec waitpid_with_retry flags pid =
	let open Unix in
	try waitpid flags pid
	with Unix_error (EINTR, _, _) -> waitpid_with_retry flags pid

let resolve commands vars =
	commands |> OpamFilter.commands (Vars.lookup vars)

let run env get_commands =
	let commands = resolve (get_commands env.spec) env.vars in
	commands |> List.iter (fun args ->
		match args with
			| [] -> ()
			| command :: _ -> begin
				let open Unix in
				prerr_endline ("+ " ^ String.concat " " args);
				let pid = create_process command (args |> Array.of_list) stdin stdout stderr in
				let (_, status) = waitpid_with_retry [] pid in
				let quit code = prerr_endline "Command failed."; exit code in
				match status with
					| WEXITED 0 -> ()
					| WEXITED code -> quit code
					| _ -> quit 1
			end
	)

let ensure_dir_exists d =
	if not (OpamFilename.exists_dir d) then (
		Printf.eprintf "creating %s\n" (OpamFilename.Dir.to_string d);
		OpamFilename.mkdir d;
	)

let remove_empty_dir d =
	if OpamFilename.dir_is_empty d then (
		Printf.eprintf "removing empty dir %s\n" (OpamFilename.Dir.to_string d);
		OpamFilename.rmdir d;
	)

let execute_install_file state =
	let name = state.pkgname in
	let install_file_path = (name ^ ".install") in
	if (Sys.file_exists install_file_path) then (
		prerr_endline ("Installing from " ^ install_file_path);
		let cmd =  [|
			"opam-installer"; "--prefix"; destDir (); install_file_path
		|] in
		let cmd_desc = String.concat " " (Array.to_list cmd) in
		prerr_endline (" + " ^ cmd_desc);
		let open Unix in
		let pid = Unix.create_process (Array.get cmd 0) cmd Unix.stdin Unix.stdout Unix.stderr in
		match waitpid_with_retry [ WUNTRACED ] pid with
			| (_, WEXITED 0) -> ()
			| _ -> failwith (cmd_desc ^ " failed")
	) else (
		prerr_endline "no .install file found!";
	)

let isdir path =
	let open Unix in
	try (stat path).st_kind = S_DIR
	with Unix_error(ENOENT, _, _) -> false

let apply_patches env =
	(* extracted from OpamAction.prepare_package_build *)
	let opam = env.spec in
	let filter_env = Vars.lookup env.vars in

	(* Substitute the patched files.*)
	let patches = OpamFile.OPAM.patches opam in

	let iter_patches f =
		List.fold_left (fun acc (base, filter) ->
			let fail e =
				OpamStd.Exn.fatal e;
				OpamFilename.Base.to_string base :: acc
			in
			let filename_str = (OpamFilename.Base.to_string base) in
			if OpamFilter.opt_eval_to_bool (filter_env) filter
			then (
				Printf.eprintf "applying patch: %s\n" filename_str;
				let result = try f filename_str with e -> Some e in
				match result with
					| Some (e: exn) -> fail e
					| None -> acc
				)
			else (
				Printf.eprintf "skipping patch: %s\n" filename_str;
				acc
			)
		) [] patches in

	let all = OpamFile.OPAM.substs opam in
	let patches =
		OpamStd.List.filter_map (fun (f,_) ->
			if List.mem f all then Some f else None
		) patches in
	List.iter
		(OpamFilter.expand_interpolations_in_file (filter_env))
		patches;

	(* Apply the patches *)
	let patching_errors =
		iter_patches (fun filename ->
			OpamSystem.patch ~dir:(Sys.getcwd ()) filename |> OpamProcess.Job.run
		)
	in

	(* Substitute the configuration files. We should be in the right
		 directory to get the correct absolute path for the
		 substitution files (see [substitute_file] and
		 [OpamFilename.of_basename]. *)
	List.iter
		(OpamFilter.expand_interpolations_in_file (filter_env))
		(OpamFile.OPAM.substs opam);

	if patching_errors <> [] then (
		let msg =
			Printf.sprintf "These patches didn't apply:\n%s"
				(OpamStd.Format.itemize (fun x -> x) patching_errors)
		in
		failwith msg
	)

let binDir dest =
	let open OpamFilename.Op in
	dest / "bin"

let libDir dest =
	let open OpamFilename.Op in
	dest / "lib"

let stublibsDir dest =
	let open OpamFilename.Op in
	(libDir dest) / "stublibs"

let outputDirs dest = [ binDir dest; stublibsDir dest; libDir dest ]

let pre_build env =
	let dest = destDir () |> OpamFilename.Dir.of_string in
	ensure_dir_exists dest;
	outputDirs dest |> List.iter ensure_dir_exists;
	apply_patches env

let build env =
	pre_build env;
	run env OPAM.build

let install env =
	run env OPAM.install;
	execute_install_file env;
	let dest = destDir () |> OpamFilename.Dir.of_string in
	outputDirs dest |> List.iter remove_empty_dir

let dump env =
	let dump desc get_commands =
		let commands = resolve (get_commands env.spec) env.vars in
		Printf.printf "# %s:\n" desc;
		commands |> List.iter (fun args ->
			Printf.printf "+ %s\n" (String.concat " " args)
		)
	in
	dump "build" OPAM.build;
	dump "install" OPAM.install

let main idx args =
	let action = try Some (Array.get args (idx+1)) with Not_found -> None in
	let action = match action with
		| Some "prebuild" -> pre_build
		| Some "build" -> build
		| Some "install"-> install
		| Some "dump"-> dump
		| Some other -> failwith ("Unknown action: " ^ other)
		| None -> failwith "No action given"
	in
	Unix.putenv "PREFIX" (destDir ());
	action (load_env ())

