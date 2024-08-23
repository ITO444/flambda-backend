[@@@ocaml.warning "+a-40-41-42"]

(* Finds independent scalar operations within the same basic block and tries to
   use vector operations if possible *)
(* CR-soon tip: add documentation *)

module DLL = Flambda_backend_utils.Doubly_linked_list

let ( << ) f g x = f (g x)

let vector_width_in_bytes = 16

module Instruction : sig
  (* CR-someday tip: consider moving this to cfg or at least have something
     similar there *)
  module Id : sig
    type t

    include Identifiable.S with type t := t

    val to_int : t -> int
  end

  type t =
    | Basic of Cfg.basic Cfg.instruction
    | Terminator of Cfg.terminator Cfg.instruction

  val op : t -> Cfg.operation option

  val is_supported_isomorphic_instructions : t list -> bool

  val have_isomorphic_op : t -> t -> bool

  val id : t -> Id.t

  val arguments : t -> Reg.t Array.t

  val results : t -> Reg.t Array.t

  val destroyed : t -> Reg.t Array.t

  val print : Format.formatter -> t -> unit

  val is_load : t -> bool

  val is_store : t -> bool

  val is_alloc : t -> bool

  val can_cross_loads_or_stores : t -> bool

  val preserves_alloc_freshness : t -> bool

  val body_of : Cfg.basic_block -> t DLL.t

  val tbl_of : Cfg.basic_block -> t Id.Tbl.t

  val find_last_instruction : t DLL.t -> Id.t list -> t
end = struct
  module Id = struct
    include Numbers.Int

    let to_int t = t
  end

  type t =
    | Basic of Cfg.basic Cfg.instruction
    | Terminator of Cfg.terminator Cfg.instruction

  let op (instruction : t) : Cfg.operation option =
    match instruction with
    | Basic basic_instruction -> (
      let desc = basic_instruction.desc in
      match desc with
      | Op op -> Some op
      | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ -> None)
    | Terminator _ -> None

  let supported instruction =
    match op instruction with
    | None -> false
    | Some op -> (
      match op with
      | Move | Const_int _ | Load _ | Store _ | Intop _ | Intop_imm _ -> true
      | Specific specific_operation ->
        Arch.supports_vectorize specific_operation
      | Alloc _ | Reinterpret_cast _ | Static_cast _ | Spill | Reload
      | Const_float32 _ | Const_float _ | Const_symbol _ | Const_vec128 _
      | Stackoffset _ | Intop_atomic _ | Floatop _ | Csel _ | Probe_is_enabled _
      | Opaque | Begin_region | End_region | Name_for_debugger _ | Dls_get
      | Poll ->
        false)

  let op_isomorphic (op1 : Cfg.operation) (op2 : Cfg.operation) =
    match op1, op2 with
    | Move, Move
    | Spill, Spill
    | Reload, Reload
    | Const_int _, Const_int _
    | Const_float32 _, Const_float32 _
    | Const_float _, Const_float _
    | Const_symbol _, Const_symbol _
    | Const_vec128 _, Const_vec128 _ ->
      true
    | ( Load
          { memory_chunk = memory_chunk1;
            addressing_mode = addressing_mode1;
            mutability = mutability1;
            is_atomic = is_atomic1
          },
        Load
          { memory_chunk = memory_chunk2;
            addressing_mode = addressing_mode2;
            mutability = mutability2;
            is_atomic = is_atomic2
          } ) ->
      Cmm.equal_memory_chunk memory_chunk1 memory_chunk2
      && Arch.compare_addressing_mode_without_displ addressing_mode1
           addressing_mode2
         = 0
      && mutability1 = mutability2 && is_atomic1 = is_atomic2
    | ( Store (memory_chunk1, addressing_mode1, is_assignment1),
        Store (memory_chunk2, addressing_mode2, is_assignment2) ) ->
      Cmm.equal_memory_chunk memory_chunk1 memory_chunk2
      && Arch.compare_addressing_mode_without_displ addressing_mode1
           addressing_mode2
         = 0
      && is_assignment1 = is_assignment2
    | Intop intop1, Intop intop2 -> Mach.equal_integer_operation intop1 intop2
    | Intop_imm (intop1, _), Intop_imm (intop2, _) ->
      Mach.equal_integer_operation intop1 intop2
    | Floatop (width1, floatop1), Floatop (width2, floatop2) ->
      Mach.equal_float_width width1 width2
      && Mach.equal_float_operation floatop1 floatop2
    | Specific specific_operation1, Specific specific_operation2 ->
      Arch.equal_specific_operation specific_operation1 specific_operation2
      (* CR-soon tip: [Arch.equal_specific_operation] may return false even if
         some operations are isomorphic (ie. when they have different
         constants) *)
    | Move, _
    | Spill, _
    | Reload, _
    | Const_int _, _
    | Const_float32 _, _
    | Const_float _, _
    | Const_symbol _, _
    | Const_vec128 _, _
    | Stackoffset _, _
    | Load _, _
    | Store _, _
    | Intop _, _
    | Intop_imm _, _
    | Intop_atomic _, _
    | Floatop _, _
    | Csel _, _
    | Reinterpret_cast _, _
    | Static_cast _, _
    | Probe_is_enabled _, _
    | Opaque, _
    | Begin_region, _
    | End_region, _
    | Specific _, _
    | Name_for_debugger _, _
    | Dls_get, _
    | Poll, _
    | Alloc _, _ ->
      false

  let have_isomorphic_op instruction1 instruction2 =
    match op instruction1, op instruction2 with
    | Some op1, Some op2 -> op_isomorphic op1 op2
    | _ -> false

  let is_supported_isomorphic_instructions instructions =
    let rec check hd1 tl1 =
      match tl1 with
      | [] -> true
      | hd2 :: tl2 ->
        if have_isomorphic_op hd1 hd2 then check hd2 tl2 else false
    in
    match instructions with
    | [] -> assert false
    | hd :: tl -> supported hd && check hd tl

  let id (instruction : t) : Id.t =
    match instruction with
    | Basic instruction -> instruction.id
    | Terminator instruction -> instruction.id

  let arguments (instruction : t) : Reg.t Array.t =
    match instruction with
    | Basic instruction -> instruction.arg
    | Terminator instruction -> instruction.arg

  let results (instruction : t) : Reg.t Array.t =
    match instruction with
    | Basic instruction -> instruction.res
    | Terminator instruction -> instruction.res

  let destroyed (instruction : t) : Reg.t Array.t =
    match instruction with
    | Basic instruction -> Proc.destroyed_at_basic instruction.desc
    | Terminator instruction -> Proc.destroyed_at_terminator instruction.desc

  let print ppf (instruction : t) : unit =
    match instruction with
    | Basic i -> Cfg.print_basic ppf i
    | Terminator i -> Cfg.print_terminator ppf i

  let is_load (instruction : t) =
    match instruction with
    | Basic basic_instruction -> (
      let desc = basic_instruction.desc in
      match desc with
      | Op op -> (
        match op with
        | Load _ -> true
        | Store _ | Alloc _ | Move | Reinterpret_cast _ | Static_cast _ | Spill
        | Reload | Const_int _ | Const_float32 _ | Const_float _
        | Const_symbol _ | Const_vec128 _ | Stackoffset _ | Intop _
        | Intop_imm _ | Intop_atomic _ | Floatop _ | Csel _ | Probe_is_enabled _
        | Opaque | Begin_region | End_region | Specific _ | Name_for_debugger _
        | Dls_get | Poll ->
          false)
      | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ -> false
      )
    | Terminator _ -> false

  let is_store (instruction : t) =
    match instruction with
    | Basic basic_instruction -> (
      let desc = basic_instruction.desc in
      match desc with
      | Op op -> (
        match op with
        | Store _ -> true
        | Load _ | Alloc _ | Move | Reinterpret_cast _ | Static_cast _ | Spill
        | Reload | Const_int _ | Const_float32 _ | Const_float _
        | Const_symbol _ | Const_vec128 _ | Stackoffset _ | Intop _
        | Intop_imm _ | Intop_atomic _ | Floatop _ | Csel _ | Probe_is_enabled _
        | Opaque | Begin_region | End_region | Specific _ | Name_for_debugger _
        | Dls_get | Poll ->
          false)
      | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ -> false
      )
    | Terminator _ -> false

  let is_alloc (instruction : t) =
    match instruction with
    | Basic basic_instruction -> (
      let desc = basic_instruction.desc in
      match desc with
      | Op op -> (
        match op with
        | Alloc _ -> true
        | Load _ | Store _ | Move | Reinterpret_cast _ | Static_cast _ | Spill
        | Reload | Const_int _ | Const_float32 _ | Const_float _
        | Const_symbol _ | Const_vec128 _ | Stackoffset _ | Intop _
        | Intop_imm _ | Intop_atomic _ | Floatop _ | Csel _ | Probe_is_enabled _
        | Opaque | Begin_region | End_region | Specific _ | Name_for_debugger _
        | Dls_get | Poll ->
          false)
      | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ -> false
      )
    | Terminator _ -> false

  let can_cross_loads_or_stores (instruction : t) =
    (* CR-someday tip: some instructions may or may not cause issues for going
       across a load or a store, for simplicity's sake, let's just return false
       and not let them go across for now, but better handling can be added in
       the future *)
    match instruction with
    | Basic basic_instruction -> (
      let desc = basic_instruction.desc in
      match desc with
      | Op op -> (
        match op with
        | Load _ | Store _ | Intop_atomic _ | Alloc _ | Poll | Opaque
        | Begin_region | End_region ->
          false
        | Specific specific_operation ->
          Arch.can_cross_loads_or_stores specific_operation
        | Move | Reinterpret_cast _ | Static_cast _ | Spill | Reload
        | Const_int _ | Const_float32 _ | Const_float _ | Const_symbol _
        | Const_vec128 _ | Stackoffset _ | Intop _ | Intop_imm _ | Floatop _
        | Csel _ | Probe_is_enabled _ | Name_for_debugger _ | Dls_get ->
          true)
      | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ -> true)
    | Terminator _ -> false

  let preserves_alloc_freshness (instruction : t) =
    match instruction with
    | Basic basic_instruction -> (
      let desc = basic_instruction.desc in
      match desc with
      | Op op -> (
        match op with
        | Load _ | Store _ -> false
        | Specific specific_operation ->
          Arch.preserves_alloc_freshness specific_operation
        | Alloc _ | Move | Reinterpret_cast _ | Static_cast _ | Spill | Reload
        | Const_int _ | Const_float32 _ | Const_float _ | Const_symbol _
        | Const_vec128 _ | Stackoffset _ | Intop _ | Intop_imm _
        | Intop_atomic _ | Floatop _ | Csel _ | Probe_is_enabled _ | Opaque
        | Begin_region | End_region | Name_for_debugger _ | Dls_get | Poll ->
          true)
      | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ -> true)
    | Terminator _ -> false

  let body_of (block : Cfg.basic_block) =
    DLL.to_list block.body
    |> List.map (fun basic_instruction -> Basic basic_instruction)
    |> DLL.of_list

  let tbl_of block =
    body_of block |> DLL.to_list
    |> List.map (fun instruction -> id instruction, instruction)
    |> Id.Tbl.of_list

  let find_last_instruction body instructions =
    let starting_cell = DLL.last_cell body in
    let instruction_set = Id.Set.of_list instructions in
    let rec find_last cell_option =
      match cell_option with
      | None -> assert false
      | Some cell ->
        let current_instruction = DLL.value cell in
        let current_instruction_id = id current_instruction in
        if Id.Set.exists (Id.equal current_instruction_id) instruction_set
        then current_instruction
        else find_last (DLL.prev cell)
    in
    find_last starting_cell
end

module Dependency_graph : sig
  (* The dependency graph shows dependencies between instructions within the
     same basic block *)
  type t

  val from_block : Cfg.basic_block -> t

  val get_arg_dependency :
    t -> Instruction.Id.t -> arg_i:int -> Instruction.Id.t option

  val get_all_dependencies_of_arg :
    t -> Instruction.Id.t -> arg_i:int -> Instruction.Id.Set.t

  val dump : Format.formatter -> t -> Cfg.basic_block -> unit
end = struct
  module Node = struct
    module Reg_node = struct
      type t =
        { reg : Reg.t;
          direct_dependency : Instruction.Id.t option
              (* the most recent instruction in this basic block that may change
                 the value of the argument *)
        }

      let init reg : t = { reg; direct_dependency = None }
    end

    type t =
      { instruction : Instruction.t;
        reg_nodes : Reg_node.t array;
        direct_dependencies : Instruction.Id.Set.t;
            (* direct dependencies of all arguments of this instruction *)
        all_dependencies : Instruction.Id.Set.t;
            (* direct dependencies of this instruction and all dependencies of
               each direct dependency of this instruction *)
        is_direct_dependency_of : Instruction.Id.Set.t
            (* all instructions that have this instruction as a direct
               dependency *)
      }

    let init instruction : t =
      let arguments = Instruction.arguments instruction in
      { instruction;
        reg_nodes =
          Array.init (Array.length arguments) (fun i ->
              Reg_node.init arguments.(i));
        direct_dependencies = Instruction.Id.Set.empty;
        all_dependencies = Instruction.Id.Set.empty;
        is_direct_dependency_of = Instruction.Id.Set.empty
      }
  end

  type t = Node.t Instruction.Id.Tbl.t

  let add = Instruction.Id.Tbl.add

  let find = Instruction.Id.Tbl.find

  let replace = Instruction.Id.Tbl.replace

  let init () : t = Instruction.Id.Tbl.create 100

  let get_arg_dependency dependency_graph id ~arg_i =
    let (node : Node.t) = Instruction.Id.Tbl.find dependency_graph id in
    node.reg_nodes.(arg_i).direct_dependency

  let get_all_dependencies dependency_graph id =
    let (node : Node.t) = Instruction.Id.Tbl.find dependency_graph id in
    node.all_dependencies

  let get_all_dependencies_of_arg dependency_graph id ~arg_i =
    let arg_dependency = get_arg_dependency dependency_graph id ~arg_i in
    match arg_dependency with
    | None -> Instruction.Id.Set.empty
    | Some direct_dependency ->
      get_all_dependencies dependency_graph direct_dependency
      |> Instruction.Id.Set.add direct_dependency

  let from_block (block : Cfg.basic_block) =
    let dependency_graph = init () in
    let is_changed_in instruction reg =
      Array.exists (Reg.same reg) (Instruction.results instruction)
      || Array.exists (Reg.same reg) (Instruction.destroyed instruction)
    in
    let latest_change ~(current : Instruction.Id.t) (reg : Reg.t) =
      let body = Instruction.body_of block in
      let starting_cell =
        match
          DLL.find_cell_opt body ~f:(fun instruction ->
              Instruction.id instruction |> Instruction.Id.equal current)
        with
        | None -> DLL.last_cell body
        | Some current_cell -> DLL.prev current_cell
      in
      let rec find_latest_change cell_option =
        match cell_option with
        | None -> None
        | Some cell ->
          let instruction = DLL.value cell in
          if is_changed_in instruction reg
          then Some instruction
          else find_latest_change (DLL.prev cell)
      in
      find_latest_change starting_cell
    in
    let add_arg_dependency instruction arg_i arg =
      let id = Instruction.id instruction in
      let dependency = latest_change ~current:id arg in
      let node = find dependency_graph id in
      let reg_node = node.reg_nodes.(arg_i) in
      node.reg_nodes.(arg_i)
        <- { reg_node with
             direct_dependency =
               Option.fold ~none:None
                 ~some:(Option.some << Instruction.id)
                 dependency
           }
    in
    let add_arg_dependencies (instruction : Instruction.t) =
      Array.iteri
        (add_arg_dependency instruction)
        (Instruction.arguments instruction)
    in
    let add_dependencies (instruction : Instruction.t) =
      let id = Instruction.id instruction in
      add dependency_graph id (Node.init instruction);
      add_arg_dependencies instruction;
      let arg_indices =
        Instruction.arguments instruction |> Array.mapi (fun arg_i _ -> arg_i)
      in
      let direct_dependencies =
        Array.fold_left
          (fun dependencies arg_i ->
            Option.fold ~none:dependencies
              ~some:(fun dependency ->
                Instruction.Id.Set.add dependency dependencies)
              (find dependency_graph id).reg_nodes.(arg_i).direct_dependency)
          Instruction.Id.Set.empty arg_indices
      in
      let all_dependencies =
        Instruction.Id.Set.fold
          (fun new_id old_indirect_dependencies ->
            let node = Instruction.Id.Tbl.find dependency_graph new_id in
            Instruction.Id.Set.union node.direct_dependencies
              old_indirect_dependencies)
          direct_dependencies direct_dependencies
      in
      let node = find dependency_graph id in
      replace dependency_graph id
        { node with direct_dependencies; all_dependencies }
    in
    let add_all_dependencies () =
      DLL.iter block.body ~f:(fun instruction ->
          add_dependencies (Basic instruction));
      add_dependencies (Terminator block.terminator)
    in
    let set_is_dependency_of instruction_id dependency_id =
      let dependency = find dependency_graph dependency_id in
      replace dependency_graph dependency_id
        { dependency with
          is_direct_dependency_of =
            Instruction.Id.Set.add instruction_id
              dependency.is_direct_dependency_of
        }
    in
    let set_is_dependency_of_plural (instruction : Instruction.t) =
      let id = Instruction.id instruction in
      let node = find dependency_graph id in
      Instruction.Id.Set.iter (set_is_dependency_of id) node.direct_dependencies
    in
    let set_all_is_dependency_of () =
      DLL.iter block.body ~f:(fun instruction ->
          set_is_dependency_of_plural (Basic instruction));
      set_is_dependency_of_plural (Terminator block.terminator)
    in
    add_all_dependencies ();
    set_all_is_dependency_of ();
    dependency_graph

  let dump ppf (t : t) (block : Cfg.basic_block) =
    let open Format in
    let print_reg_node arg_i (reg_node : Node.Reg_node.t) =
      let dependency =
        Option.fold ~none:"none"
          ~some:(sprintf "instruction %d" << Instruction.Id.to_int)
          reg_node.direct_dependency
      in
      fprintf ppf "argument %d, %a depends on %s\n" arg_i Printmach.reg
        reg_node.reg dependency
    in
    let print_node (instruction : Instruction.t) =
      let id = Instruction.id instruction in
      let node = find t id in
      fprintf ppf "\n%d:\n"
        (Instruction.id node.instruction |> Instruction.Id.to_int);
      Instruction.print ppf instruction;
      fprintf ppf "\ndirect dependencies:\n";
      Instruction.Id.Set.iter
        (fprintf ppf "%d " << Instruction.Id.to_int)
        node.direct_dependencies;
      fprintf ppf "\nall dependencies:\n";
      Instruction.Id.Set.iter
        (fprintf ppf "%d " << Instruction.Id.to_int)
        node.all_dependencies;
      fprintf ppf "\nis direct dependency of:\n";
      Instruction.Id.Set.iter
        (fprintf ppf "%d " << Instruction.Id.to_int)
        node.is_direct_dependency_of;
      fprintf ppf "\narg dependencies:\n";
      Array.iteri print_reg_node node.reg_nodes;
      fprintf ppf "\n"
    in
    fprintf ppf "\ndependency graph:\n";
    DLL.iter block.body ~f:(fun instruction -> print_node (Basic instruction));
    print_node (Terminator block.terminator);
    fprintf ppf "\n"
end

module Memory_accesses : sig
  module Memory_operation : sig
    type t

    val instruction : t -> Instruction.t

    val width : t -> int

    val dump : Format.formatter -> t -> unit
  end

  type t

  val stores : t -> Instruction.Id.t list

  val get_memory_operation_exn : t -> Instruction.Id.t -> Memory_operation.t

  val from_block : Cfg.basic_block -> t

  val all_adjacent : t -> Instruction.Id.t list -> bool

  val inter_independent : t -> Instruction.t list -> bool

  val can_group :
    ?remove:bool -> t -> Instruction.t DLL.t -> Instruction.Id.t list -> bool

  val dump : Format.formatter -> t -> unit
end = struct
  module Memory_operation = struct
    type op =
      | Load
      | Store

    type t =
      { op : op;
        memory_chunk : Cmm.memory_chunk;
        addressing_mode : Arch.addressing_mode;
        instruction : Instruction.t;
        dependent_allocs : Instruction.Id.Set.t;
        unsure_allocs : Instruction.Id.Set.t
      }

    let instruction t = t.instruction

    let init (instruction : Instruction.t) : t option =
      match instruction with
      | Basic basic_instruction -> (
        let desc = basic_instruction.desc in
        match desc with
        | Op op -> (
          match op with
          | Load { memory_chunk; addressing_mode; _ } ->
            Some
              { op = Load;
                memory_chunk;
                addressing_mode;
                instruction;
                dependent_allocs = Instruction.Id.Set.empty;
                unsure_allocs = Instruction.Id.Set.empty
              }
          | Store (memory_chunk, addressing_mode, _) ->
            Some
              { op = Store;
                memory_chunk;
                addressing_mode;
                instruction;
                dependent_allocs = Instruction.Id.Set.empty;
                unsure_allocs = Instruction.Id.Set.empty
              }
          | Specific _ ->
            None
            (* CR-someday tip: may need to rewrite a lot of code to handle loads
               and stores inside [Specific] in the future *)
          | Move | Reinterpret_cast _ | Static_cast _ | Spill | Reload
          | Const_int _ | Const_float32 _ | Const_float _ | Const_symbol _
          | Const_vec128 _ | Stackoffset _ | Intop _ | Intop_imm _
          | Intop_atomic _ | Floatop _ | Csel _ | Probe_is_enabled _ | Opaque
          | Begin_region | End_region | Name_for_debugger _ | Dls_get | Poll
          | Alloc _ ->
            None)
        | Reloadretaddr | Pushtrap _ | Poptrap | Prologue | Stack_check _ ->
          None)
      | Terminator _ -> None

    let memory_arguments (t : t) =
      let arguments = Instruction.arguments t.instruction in
      match t.op with
      | Load -> arguments
      | Store -> Array.sub arguments 1 (Array.length arguments - 1)

    let width (t : t) = Cmm.width_of t.memory_chunk

    let print_memory_chunk ppf (t : t) =
      Format.fprintf ppf "%s (length %d)"
        (Printcmm.chunk t.memory_chunk)
        (Cmm.width_of t.memory_chunk)

    let dump ppf (t : t) =
      let open Format in
      let instruction = t.instruction in
      let print_set ppf set =
        Instruction.Id.Set.iter
          (fun id -> fprintf ppf "%d " (Instruction.Id.to_int id))
          set
      in
      fprintf ppf
        "\n\
         Instruction %d: %a (%a, %a)\n\
        \ dependent allocs: %a\n\
        \ unsure_allocs: %a"
        (Instruction.id instruction |> Instruction.Id.to_int)
        Instruction.print instruction print_memory_chunk t
        (Arch.print_addressing Printmach.reg t.addressing_mode)
        (memory_arguments t) print_set t.dependent_allocs print_set
        t.unsure_allocs

    let compare_arguments (t1 : t) (t2 : t) =
      let arguments_1 = memory_arguments t1 in
      let arguments_2 = memory_arguments t2 in
      Array.combine arguments_1 arguments_2
      |> Array.fold_left
           (fun result ((arg1, arg2) : Reg.t * Reg.t) ->
             if result = 0 then Reg.compare arg1 arg2 else result)
           0

    let compare_addressing_modes_and_arguments (t1 : t) (t2 : t) =
      let addressing_mode_comparison =
        Arch.compare_addressing_mode_without_displ t1.addressing_mode
          t2.addressing_mode
      in
      if addressing_mode_comparison = 0
      then
        let arguments_comparison = compare_arguments t1 t2 in
        arguments_comparison
      else addressing_mode_comparison

    let offset_of (t1 : t) (t2 : t) =
      let addressing_mode_and_arguments_comparison =
        compare_addressing_modes_and_arguments t1 t2
      in
      if addressing_mode_and_arguments_comparison = 0
      then Arch.addressing_offset t1.addressing_mode t2.addressing_mode
      else None

    let is_adjacent (t1 : t) (t2 : t) =
      let res =
        if Instruction.have_isomorphic_op t1.instruction t2.instruction
        then
          let width = Cmm.width_of t1.memory_chunk in
          let offset_option = offset_of t1 t2 in
          match offset_option with
          | None -> false
          | Some offset -> width = offset
        else false
      in
      res
  end

  type t =
    { loads : Instruction.Id.t list;
      stores : Instruction.Id.t list;
      memory_operations : Memory_operation.t Instruction.Id.Tbl.t
    }

  let stores t = t.stores

  let get_memory_operation_exn t id =
    Instruction.Id.Tbl.find t.memory_operations id

  let from_block (block : Cfg.basic_block) : t =
    (* A heuristic to avoid treating the same "fresh" allocation which address
       stored and loaded into a different register as different, has room for
       improvement. Assumption: if x depends on a fresh allocation, and it is
       certain that y does not depend on that fresh allocation, then they point
       to disjoint addresses *)
    (* At each load or store instruction, it keeps track of all allocs up to
       this point in this basic block and puts them in one of 3 categories:
       [fresh_allocs]: nothing that depends on the address of the fresh alloc
       has been saved as a value; [stored_allocs]: something that depends on the
       address of the fresh alloc has been saved as a value, but nothing has
       been loaded till this point; [unsure_allocs]: something that depends on
       the address of the fresh alloc has been saved as a value, and something
       has been loaded till this point. For each memory operation, we will save
       its dependent allocs and unsure allocs *)
    let dependency_graph = Dependency_graph.from_block block in
    let body = Instruction.body_of block in
    let id_to_instructions = Instruction.tbl_of block in
    let memory_operations = Instruction.Id.Tbl.create 100 in
    let loads, stores, _, _, _ =
      DLL.fold_left body
        ~f:
          (fun (loads, stores, fresh_allocs, stored_allocs, unsure_allocs)
               instruction ->
          let id = Instruction.id instruction in
          if Instruction.is_alloc instruction
          then
            ( loads,
              stores,
              Instruction.Id.Set.add id fresh_allocs,
              stored_allocs,
              unsure_allocs )
          else
            let memory_operation = Memory_operation.init instruction in
            match memory_operation with
            | None ->
              if Instruction.preserves_alloc_freshness instruction
              then loads, stores, fresh_allocs, stored_allocs, unsure_allocs
              else
                ( loads,
                  stores,
                  Instruction.Id.Set.empty,
                  Instruction.Id.Set.empty,
                  Instruction.Id.Set.union fresh_allocs stored_allocs
                  |> Instruction.Id.Set.union unsure_allocs )
            | Some memory_operation -> (
              let get_dependent_allocs_of_arg arg_i =
                Dependency_graph.get_all_dependencies_of_arg dependency_graph id
                  ~arg_i
                |> Instruction.Id.Set.filter
                     (Instruction.is_alloc
                     << Instruction.Id.Tbl.find id_to_instructions)
              in
              let start_index =
                match memory_operation.op with Load -> 0 | Store -> 1
              in
              let dependent_allocs, _ =
                Array.fold_left
                  (fun (dependent_allocs, arg_i) _ ->
                    ( get_dependent_allocs_of_arg arg_i
                      |> Instruction.Id.Set.union dependent_allocs,
                      arg_i + 1 ))
                  (Instruction.Id.Set.empty, start_index)
                  (Memory_operation.memory_arguments memory_operation)
              in
              match memory_operation.op with
              | Load ->
                Instruction.Id.Tbl.add memory_operations id
                  { memory_operation with dependent_allocs; unsure_allocs };
                ( id :: loads,
                  stores,
                  fresh_allocs,
                  Instruction.Id.Set.empty,
                  Instruction.Id.Set.union stored_allocs unsure_allocs )
              | Store ->
                Instruction.Id.Tbl.add memory_operations id
                  { memory_operation with dependent_allocs; unsure_allocs };
                let new_stored_allocs =
                  Instruction.Id.Set.diff
                    (get_dependent_allocs_of_arg 0)
                    unsure_allocs
                in
                ( loads,
                  id :: stores,
                  Instruction.Id.Set.diff fresh_allocs new_stored_allocs,
                  Instruction.Id.Set.union stored_allocs new_stored_allocs,
                  unsure_allocs )))
        ~init:
          ( [],
            [],
            Instruction.Id.Set.empty,
            Instruction.Id.Set.empty,
            Instruction.Id.Set.empty )
    in
    { loads = List.rev loads; stores = List.rev stores; memory_operations }

  let can_cross t instruction_1 instruction_2 =
    let reg_array_to_set = Reg.Set.of_list << Array.to_list in
    let argument_set = reg_array_to_set << Instruction.arguments
    and affected_set instruction =
      Reg.Set.union
        (Instruction.results instruction |> reg_array_to_set)
        (Instruction.destroyed instruction |> reg_array_to_set)
    in
    let arguments_1 = argument_set instruction_1
    and affected_1 = affected_set instruction_1
    and arguments_2 = argument_set instruction_2
    and affected_2 = affected_set instruction_2 in
    if Reg.Set.disjoint affected_1 affected_2
       && Reg.Set.disjoint arguments_1 affected_2
       && Reg.Set.disjoint affected_1 arguments_2
    then
      let get_memory_operation instruction =
        Instruction.Id.Tbl.find_opt t.memory_operations
          (Instruction.id instruction)
      in
      match
        get_memory_operation instruction_1, get_memory_operation instruction_2
      with
      | None, _ | _, None ->
        Instruction.can_cross_loads_or_stores instruction_1
        || Instruction.can_cross_loads_or_stores instruction_2
      | Some memory_operation_1, Some memory_operation_2 -> (
        match memory_operation_1.op, memory_operation_2.op with
        | Load, Load -> true
        | Load, Store | Store, Load | Store, Store ->
          if Memory_operation.compare_addressing_modes_and_arguments
               memory_operation_1 memory_operation_2
             = 0
          then
            let check_direct_separation left_memory_operation
                right_memory_operation =
              match
                Memory_operation.offset_of left_memory_operation
                  right_memory_operation
              with
              | None -> false
              | Some offset ->
                offset
                > Cmm.width_of
                    left_memory_operation.Memory_operation.memory_chunk
            in
            check_direct_separation memory_operation_1 memory_operation_2
            || check_direct_separation memory_operation_2 memory_operation_1
          else
            Instruction.Id.Set.is_empty
              (Instruction.Id.Set.diff memory_operation_1.dependent_allocs
                 (Instruction.Id.Set.union memory_operation_2.dependent_allocs
                    memory_operation_2.unsure_allocs))
            |> not
            || Instruction.Id.Set.is_empty
                 (Instruction.Id.Set.diff memory_operation_2.dependent_allocs
                    (Instruction.Id.Set.union
                       memory_operation_1.dependent_allocs
                       memory_operation_1.unsure_allocs))
               |> not)
    else false

  let can_cross_lists t instructions1 instructions2 =
    let can_cross_list instruction1 =
      List.fold_left
        (fun can instruction2 -> can && can_cross t instruction1 instruction2)
        true instructions2
    in
    List.fold_left
      (fun can instruction1 -> can && can_cross_list instruction1)
      true instructions1

  let all_adjacent t instructions =
    let rec check_adjacent hd1 tl1 =
      match tl1 with
      | [] -> true
      | hd2 :: tl2 ->
        if Memory_operation.is_adjacent
             (get_memory_operation_exn t hd1)
             (get_memory_operation_exn t hd2)
        then check_adjacent hd2 tl2
        else false
    in
    check_adjacent (List.hd instructions) (List.tl instructions)

  let inter_independent t instructions =
    let rec check instructions =
      match instructions with
      | [] -> true
      | hd :: tl -> if can_cross_lists t [hd] tl then check tl else false
    in
    check instructions
  (* all pairs of instruction in the group are inter-independent *)

  let can_group ?(remove = false) t body instructions =
    (* instructions can be made to be adjacent *)
    let starting_cell = DLL.hd_cell body in
    let rec can_be_together instruction_set group cell_option =
      if Instruction.Id.Set.is_empty instruction_set
      then true
      else
        match cell_option with
        | None -> false
        | Some cell ->
          let current_instruction = DLL.value cell in
          let current_instruction_id = Instruction.id current_instruction in
          let next = DLL.next cell in
          if Instruction.Id.Set.exists
               (Instruction.Id.equal current_instruction_id)
               instruction_set
          then (
            if remove then DLL.delete_curr cell;
            can_be_together
              (Instruction.Id.Set.remove current_instruction_id instruction_set)
              (current_instruction :: group)
              next)
          else if can_cross_lists t group [current_instruction]
          then can_be_together instruction_set group next
          else false
    in
    can_be_together (Instruction.Id.Set.of_list instructions) [] starting_cell

  let dump ppf ({ loads; stores; memory_operations } : t) =
    let open Format in
    let print_list list =
      List.iter
        (fun id ->
          let address = Instruction.Id.Tbl.find memory_operations id in
          Memory_operation.dump ppf address)
        list
    in
    fprintf ppf "\nmemory accesses (loads):\n";
    print_list loads;
    fprintf ppf "\nmemory accesses (stores):\n";
    print_list stores;
    fprintf ppf "\n"
end

module Seed : sig
  type t = Memory_accesses.Memory_operation.t list
  (* a seed is a group of stores instructions to adjacent memory addresses that
     can be made to be adjacent in the list of instructions *)

  val from_block : Cfg.basic_block -> t list

  val dump : Format.formatter -> t list -> unit
end = struct
  type t = Memory_accesses.Memory_operation.t list

  let from_block (block : Cfg.basic_block) : t list =
    (* For each store instruction, it tries to form a seed with the closest
       stores after it, it will go down the DLL of instructions and tries to
       move the store instructions across the non-store instructions until all
       the store instructions are together *)
    let body = Instruction.body_of block in
    let memory_accesses = Memory_accesses.from_block block in
    let all_stores = Memory_accesses.stores memory_accesses in
    List.filter_map
      (fun store_id ->
        let starting_cell =
          DLL.find_cell_opt body ~f:(fun instruction ->
              Instruction.id instruction |> Instruction.Id.equal store_id)
        in
        let rec find_stores n stores cell_option =
          if n = 0
          then Some (List.rev stores)
          else
            match cell_option with
            | None -> None
            | Some cell ->
              let instruction = DLL.value cell in
              if Instruction.is_store instruction
              then find_stores (n - 1) (instruction :: stores) (DLL.next cell)
              else find_stores n stores (DLL.next cell)
        in
        let starting_memory_operation =
          Memory_accesses.get_memory_operation_exn memory_accesses store_id
        in
        let items_in_vector =
          vector_width_in_bytes
          / Memory_accesses.Memory_operation.width starting_memory_operation
        in
        let store_group = find_stores items_in_vector [] starting_cell in
        match store_group with
        | None -> None
        | Some stores ->
          let store_ids = List.map Instruction.id stores in
          if Memory_accesses.all_adjacent memory_accesses store_ids
             && Memory_accesses.can_group memory_accesses body store_ids
          then
            Some
              (List.map
                 (fun id ->
                   Memory_accesses.get_memory_operation_exn memory_accesses id)
                 store_ids)
          else None)
      all_stores

  let dump ppf (seeds : t list) =
    let open Format in
    let print_seed seed =
      List.iter
        (fun (address : Memory_accesses.Memory_operation.t) ->
          Memory_accesses.Memory_operation.dump ppf address)
        seed
    in
    let print_seeds seeds =
      List.iter
        (fun seed ->
          fprintf ppf "(";
          print_seed seed;
          fprintf ppf "\n)\n")
        seeds
    in
    fprintf ppf "\nseeds:\n";
    print_seeds seeds;
    fprintf ppf "\n"
end

module Computation_tree : sig
  type t

  val from_block : Cfg.basic_block -> t list

  val dump : Format.formatter -> t list -> Cfg.basic_block -> unit
end = struct
  module Node = struct
    type t =
      { operation : Cfg.operation;
        instructions : Instruction.Id.t list;
        dependencies : Instruction.Id.t option array;
            (* Only counts dependencies within the same computation tree *)
        is_dependency_of : Instruction.Id.Set.t
      }

    let init instruction instruction_ids =
      match Instruction.op instruction with
      | None -> assert false
      | Some operation ->
        { operation;
          instructions = instruction_ids;
          dependencies =
            Array.make (Instruction.arguments instruction |> Array.length) None;
          is_dependency_of = Instruction.Id.Set.empty
        }
  end

  type t = Node.t Instruction.Id.Tbl.t
  (* key is the id of the instruction where the node will be inserted, which is
     the last instruction in the node for now, we can change that later *)

  let init () : t = Instruction.Id.Tbl.create 100

  let from_seed (block : Cfg.basic_block) seed =
    let body = Instruction.body_of block in
    let id_to_instructions = Instruction.tbl_of block in
    let dependency_graph = Dependency_graph.from_block block in
    let memory_accesses = Memory_accesses.from_block block in
    let find_instruction = Instruction.Id.Tbl.find id_to_instructions in
    let root =
      List.map
        (Instruction.id << Memory_accesses.Memory_operation.instruction)
        seed
    in
    let computation_tree = init () in
    let rec build instruction_ids : Instruction.Id.t option =
      let instructions = List.map find_instruction instruction_ids in
      let last_instruction =
        Instruction.find_last_instruction body instruction_ids
      in
      let all_option list =
        List.fold_right
          (fun item result ->
            match item, result with
            | Some item, Some result -> Some (item :: result)
            | _ -> None)
          list (Some [])
      in
      if Instruction.is_supported_isomorphic_instructions instructions |> not
      then None
      else
        let key = Instruction.id last_instruction in
        let node : Node.t = Node.init last_instruction instruction_ids in
        match Instruction.Id.Tbl.find_opt computation_tree key with
        (* is there another node with the same key already in the tree *)
        | Some (old_node : Node.t) ->
          if List.equal Instruction.Id.equal node.instructions
               old_node.instructions
          then Some key
          else
            None
            (* The last instruction of the node is already in another node, if
               the other node is different from this node, we won't vectorize
               this for simplicity's sake *)
        | None ->
          if Instruction.is_load last_instruction
          then
            if Memory_accesses.all_adjacent memory_accesses instruction_ids
               && Memory_accesses.inter_independent memory_accesses instructions
            then (
              Instruction.Id.Tbl.add computation_tree key node;
              Some key)
            else None
          else if Instruction.is_store last_instruction
                  && Memory_accesses.all_adjacent memory_accesses
                       instruction_ids
                  || (not (Instruction.is_store last_instruction))
                     && Memory_accesses.inter_independent memory_accesses
                          instructions
          then (
            Instruction.Id.Tbl.add computation_tree key node;
            let build_dependencies () =
              Array.mapi
                (fun arg_i _ ->
                  match
                    List.map
                      (Dependency_graph.get_arg_dependency dependency_graph
                         ~arg_i)
                      instruction_ids
                    |> all_option
                  with
                  | None -> None
                  | Some new_instructions -> build new_instructions)
                (Instruction.arguments last_instruction)
            in
            Instruction.Id.Tbl.replace computation_tree key
              { node with dependencies = build_dependencies () };
            Some key)
          else None
    in
    let is_valid computation_tree =
      let check cell =
        match
          DLL.value cell |> Instruction.id
          |> Instruction.Id.Tbl.find_opt computation_tree
        with
        | None -> true
        | Some (node : Node.t) ->
          Memory_accesses.can_group ~remove:true memory_accesses body
            node.instructions
      in
      let rec validate cell_option =
        match cell_option with
        | None -> true
        | Some cell -> if check cell then validate (DLL.prev cell) else false
      in
      DLL.last_cell body |> validate
    in
    match build root with
    | None -> None
    | Some _ ->
      if is_valid computation_tree then Some computation_tree else None

  let from_block (block : Cfg.basic_block) : t list =
    let seeds = Seed.from_block block in
    List.filter_map (from_seed block) seeds

  let dump ppf (trees : t list) (block : Cfg.basic_block) =
    let open Format in
    let string_of dependency_option =
      Option.fold ~none:"none"
        ~some:(sprintf "%d" << Instruction.Id.to_int)
        dependency_option
    in
    let print_node id node_option =
      match node_option with
      | None -> ()
      | Some (node : Node.t) ->
        fprintf ppf "\nNode key: %d\n" (Instruction.Id.to_int id);
        fprintf ppf "\nOperation: %a\n" Cfg.dump_basic (Cfg.Op node.operation);
        fprintf ppf "\ninstructions:\n";
        List.iter (fprintf ppf "%d " << Instruction.Id.to_int) node.instructions;
        fprintf ppf "\ndependencies:\n";
        Array.iter (fprintf ppf "%s " << string_of) node.dependencies;
        fprintf ppf "\nis dependency of:\n";
        Instruction.Id.Set.iter
          (fprintf ppf "%d " << Instruction.Id.to_int)
          node.is_dependency_of;
        fprintf ppf "\n"
    in
    let print_tree tree =
      DLL.iter block.body ~f:(fun instruction ->
          let id = Basic instruction |> Instruction.id in
          Instruction.Id.Tbl.find_opt tree id |> print_node id)
    in
    let print_trees trees =
      List.iter
        (fun tree ->
          fprintf ppf "(";
          print_tree tree;
          fprintf ppf ")\n\n")
        trees
    in
    fprintf ppf "\ncomputation trees:\n";
    print_trees trees;
    fprintf ppf "\n"
end

let dump ppf cfg_with_layout ~msg =
  let open Format in
  let cfg = Cfg_with_layout.cfg cfg_with_layout in
  fprintf ppf "\nvectorization extra information for %s\n" msg;
  fprintf ppf "%s\n" (Cfg.fun_name cfg);
  let block_count = Label.Tbl.length cfg.blocks in
  fprintf ppf "blocks.length=%d\n" block_count;
  let body_instruction_count =
    Cfg.fold_body_instructions cfg ~f:(fun sum _ -> sum + 1) ~init:0
  in
  fprintf ppf "body instruction count=%d\n" body_instruction_count;
  fprintf ppf "terminator instruction count=%d\n" block_count;
  fprintf ppf "body and terminator instruction count=%d\n"
    (body_instruction_count + block_count);
  fprintf ppf "@."

let cfg ppf_dump cl =
  if !Flambda_backend_flags.dump_vectorize
  then Format.fprintf ppf_dump "*** Vectorization@.";
  let cfg = Cfg_with_layout.cfg cl in
  let layout = Cfg_with_layout.layout cl in
  DLL.iter layout ~f:(fun label ->
      let block = Cfg.get_block_exn cfg label in
      let instruction_count = DLL.length block.body in
      Format.fprintf ppf_dump "\nBlock %d (%d basic instructions):\n" label
        instruction_count;
      if instruction_count > 1000
      then
        Format.fprintf ppf_dump
          "more than 1000 instructions in basic block, cannot vectorize\n"
      else
        let dependency_graph = Dependency_graph.from_block block in
        if !Flambda_backend_flags.dump_vectorize
        then Dependency_graph.dump ppf_dump dependency_graph block;
        let memory_accesses = Memory_accesses.from_block block in
        if !Flambda_backend_flags.dump_vectorize
        then Memory_accesses.dump ppf_dump memory_accesses;
        let seeds = Seed.from_block block in
        if !Flambda_backend_flags.dump_vectorize then Seed.dump ppf_dump seeds;
        let trees = Computation_tree.from_block block in
        if !Flambda_backend_flags.dump_vectorize
        then Computation_tree.dump ppf_dump trees block);
  if !Flambda_backend_flags.dump_vectorize then dump ppf_dump ~msg:"" cl;
  cl
