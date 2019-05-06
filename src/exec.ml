open Primitives
open Utils
open Bytecode
open Types
open Types.Print
open Bytecode.Print

module Exec_Eval_Apply = struct
    open Bytecode_Eval_Apply

    module Env = struct 
        include Hashtbl.Make(struct 
            type t = var
            let equal = (=)
            let hash = Hashtbl.hash
        end)
    end

    type result = [
        | `CST of b
        | `Fail ]
        
    and stack_value = 
        [ `CST of b
        | `CLS of var * bytecode * env * kappa * mark
        | `TYP of kappa
        | `FAIL
        | `PAIR of stack_value * stack_value
        ]
    and env = stack_value Env.t

    (* machine values *)
    type nu = [
        | `CST of b
        | `CLS of var * bytecode * env * kappa * mark
    ]

    let empty : env = Env.create 0 

    type stack = stack_value list

    type dump_item = 
        | Boundary of kappa
        | Frame    of bytecode * env
    type dump = dump_item list 

    type state = bytecode * env * stack * dump

     let rec typeof_stack_value : stack_value -> t = function
        | `CST b -> cap (constant b) (t_dyn)
        | `CLS (_, _, _, (t1, _), _) -> t1
        | `PAIR (v1, v2) -> 
            let t1 = typeof_stack_value v1 in
            let t2 = typeof_stack_value v2 in pair t1 t2
        | _ -> failwith "error: trying to take typeof of `TYP or `FAIL"

    module Print = struct 
        let rec show_stack_value : stack_value -> string = function
        | `CST b -> pp_b b
        | `CLS (v, btc, env, ts, m) -> 
            Printf.sprintf "C(%s, %s, %s, %s, %s)"
            (pp_var v) (show_bytecode 2 btc) (show_env 1 true env)
            (show_kappa ts) (show_mark m)
        | `TYP k -> show_kappa k
        | `FAIL -> "Fail"
        | `PAIR (v1, v2) -> 
            Printf.sprintf "(%s, %s)" (show_stack_value v1)
            (show_stack_value v2)

        and show_env_value : int -> stack_value -> string = 
        function
        | 2 -> show_stack_value  
        | 0 -> (fun _ -> "_")
        | 1 -> show_stack_value_1
        | _ -> failwith "wrong verbose argument"

        and show_result : stack_value -> string = function
        | `CST b -> 
            Printf.sprintf ": %s = %s" (pp_tau (constant b)) (pp_b b)
        | `CLS (v, btc, _, _,_) -> 
            Printf.sprintf ": %s -> %s = <fun>" (pp_var v) (show_bytecode 2 btc)
        | `FAIL -> ": Fail"
        | `PAIR (v1, v2) as v -> 
            Printf.sprintf ": %s = (%s, %s)" (pp_tau @@ typeof_stack_value v)
            (show_stack_value v1) (show_stack_value v2) 
        | _ -> failwith "not a return value"

        and show_env : int -> bool -> env -> string =
        fun verb inline env ->
            let lenv = List.of_seq (Env.to_seq env) in
            let sep = if inline then " . " else "\n\t     " in
            if lenv = [] then "{}" else
            "{ " ^ String.concat sep
                (List.map
                    (fun (v,sv) -> Printf.sprintf "(%s := %s)"
                    (pp_var v) (show_env_value verb sv)) 
                    lenv) ^ " }"

        and show_dump_item : dump_item -> string = function
        | Boundary t -> Printf.sprintf "<%s>" (show_kappa t)
        | Frame (_,e) -> Printf.sprintf "([code], %s)" (show_env 1 true e)

        and show_dump : dump -> string =
        fun d ->
            (String.concat "\n\t   "
            (List.map show_dump_item d))

        and show_stack_value_1 : stack_value -> string = function
        | `CST b -> pp_b b
        | `CLS (x,_,env,bnd,_) -> Printf.sprintf "C(%s,...,%s, %s)" 
            (pp_var x) (show_env 0 true env) 
            @@ show_kappa bnd
        | `TYP t -> show_kappa t
        | `FAIL -> "Fail" 
        | `PAIR (v1, v2) -> 
            Printf.sprintf "(%s, %s)" (show_stack_value_1 v1)
            (show_stack_value_1 v2)

        let show_stack s verbose = 
        let show_stack_val = begin match verbose with
        | 2 -> show_stack_value
        | 1 -> show_stack_value_1
        | 0 -> fun _ -> ""
        | _ -> failwith "wrong verbose argument" end
        in
            Printf.sprintf "[ %s ]" 
            (String.concat "\n\t     "
            (List.map show_stack_val s))

    end

    module MetricsDebug = struct 
        open Print

        module MetricsEnv = Hashtbl.Make(struct 
            type t = byte
            let equal a b = match a, b with 
            | ACC _, ACC _ | CST _, CST _
            | CLS _, CLS _ | RCL _, RCL _
            | LET _, LET _ | TYP _, TYP _
            | END _, END _ | TCA _, TCA _
            | IFZ _, IFZ _ -> true
            | _ -> a = b
            let hash = Hashtbl.hash
            end)

        type metrics = 
            {mutable stack_sizes : (int * int) list;
            mutable longest_proxies : (int * int) list;
            mutable casts : (int * int) list;
            instructions : int MetricsEnv.t;
            mutable dump_sizes : (int * int) list;
            mutable env_sizes : (int * int) list
            }


        type run_params =
            {run : bool ref;
            step : int ref;
            max_stack : int ref;
            verbose : int ref;
            delim : int ref;
            debug : bool ref;
            step_mode : bool ref;
            step_start : int ref;
            monitor : bool ref;
            mutable states : state list;
            mutable metrics : metrics}


        let init_metrics : unit -> metrics = fun () ->
            {stack_sizes = [];  
            longest_proxies = []; 
            casts = [];
            instructions = MetricsEnv.create 20;
            dump_sizes = [];
            env_sizes = []
            }

        let run_params =
                {run = ref true;
                step = ref 0;
                max_stack = ref 500;
                verbose = ref 2;
                delim = ref 2;
                debug = ref true;
                step_mode = ref false;
                step_start = ref 0;
                monitor = ref false;
                states = [];
                metrics = init_metrics ()}
        
        let count_cast : stack -> int =
            let rec aux acc = function
            | [] -> acc
            | `TYP _ :: s -> aux (acc+1) s
            | _ :: s -> aux acc s
        in aux 0 

        let longest_proxy : stack -> int = 
            let rec aux max acc = function
            | [] -> max
            | `TYP _ :: s when acc+1 > max -> 
                aux (acc+1) (acc+1) s
            | `TYP _ :: s -> 
                aux max (acc+1) s
            | _ :: s -> 
                aux max 0 s
        in aux 0 0


        let gather_metrics : run_params -> state -> unit =
            fun run_params -> let met = run_params.metrics in
            fun (c, e, s, d) ->
            begin
            met.env_sizes <- (!(run_params.step), List.length (List.of_seq @@ Env.to_seq e)) :: met.env_sizes;
            met.stack_sizes <- (!(run_params.step), (List.length s)) :: met.stack_sizes;
            met.dump_sizes <- (!(run_params.step), (List.length d)) :: met.dump_sizes;
            met.longest_proxies <- (!(run_params.step), (longest_proxy s)) :: met.longest_proxies;
            met.casts <- (!(run_params.step), (count_cast s)) :: met.casts;
            run_params.metrics <- met;
            if c != [] then let instr = List.hd c in
            let cnt_inst =  
                (try MetricsEnv.find met.instructions instr
                with Not_found -> 0) in
            MetricsEnv.replace met.instructions instr (cnt_inst+1)
            end

         
        let delim n i =
            let si = string_of_int i in 
            let d = String.length si in
            String.init (n+1-d) (fun _ -> ' ')

        let rec firstk k xs = match xs with
        | [] -> []
        | x::xs -> if k=1 then [x] else x::firstk (k-1) xs;;


        let print_debug_stack run_params s =
            let stack_size = List.length s in
            if !(run_params.verbose) >= 1
            then 
            let d = delim !(run_params.delim) stack_size in
            let ssize = string_of_int stack_size in 
            let strstack = show_stack (firstk 20 s) !(run_params.verbose) in
            Printf.printf "Stack[%s]:%s%s\n" ssize d strstack
            else 
            Printf.printf "Stack[%i]\n" (stack_size) 

        let print_debug_code run_params s =
            let stack_size = List.length s in
            if !(run_params.verbose) >= 1
            then Printf.printf "Code [%i]:%s%s\n" (stack_size) 
            (delim !(run_params.delim) stack_size) 
            (show_bytecode !(run_params.verbose) (firstk 7 s))
            else Printf.printf "Code [%i]\n" (stack_size) 

        let print_debug_env run_params s =
            let stack_size = List.length (List.of_seq @@ Env.to_seq s) in
            if stack_size < 20 && !(run_params.verbose) >= 1
            then Printf.printf "Env  [%i]:%s%s\n" 
            (stack_size)
            (delim !(run_params.delim) stack_size) 
            (show_env !(run_params.verbose) false s)
            else Printf.printf "Env  [%i]\n" (stack_size) 

        let print_debug_dump run_params s =
            let stack_size = List.length s in
            if !(run_params.verbose) >= 1
            then Printf.printf "Dump [%i]:%s%s\n" (stack_size)
            (delim !(run_params.delim) stack_size) 
            (show_dump (firstk 4 s))
            else Printf.printf "Dump [%i]\n" (stack_size) 
        
        let print_debug_run run_params  = function
            | c, e, s, d -> 
            Printf.printf "==={%i}========================================================================\n" !(run_params.step);
            Pervasives.flush stdout; 
            print_debug_code run_params c;
            Pervasives.flush stdout; print_endline "";
            print_debug_stack run_params s;
            Pervasives.flush stdout; print_endline "";
            print_debug_env run_params e;
            Pervasives.flush stdout; print_endline "";
            print_debug_dump run_params d;
            Pervasives.flush stdout
    end

    module Transitions = struct
        open MetricsDebug

       

        exception Machine_Stack_Overflow

        let run_check run_params (_, _, s, _) =
            if List.length s > !(run_params.max_stack)
            then raise Machine_Stack_Overflow

        let run_procedures state = 
        begin
            run_params.step := !(run_params.step)+1;
            if !(run_params.monitor) then gather_metrics run_params state;
            if !(run_params.debug) then print_debug_run run_params state;
            run_check run_params state;
            let ref_state = ref state in
                if !(run_params.step_mode) 
                && !(run_params.step) >= !(run_params.step_start) then
                begin 
                    let cmd = read_line () in 
                    if cmd = "b" then 
                        (begin
                        ref_state := List.hd run_params.states;
                        run_params.states <- List.tl run_params.states;
                        run_params.step := !(run_params.step)-2
                        end)
                    else run_params.states <- state :: run_params.states
                end;
                !ref_state
        end

        (* parameter functions *)
        let compose : kappa -> kappa -> kappa = 
        fun (t1,t2) (t3,t4) -> ((cap t1 t3), (cap t2 t4))

        let dump : kappa -> dump -> dump = fun k -> function
        | [] -> [Boundary k]
        | Boundary k' :: d' -> Boundary (compose k k') :: d'
        | (Frame _ :: _) as d -> Boundary k :: d

        (* let cast : v -> kappa   *)

        let run code env = 
            let rec aux : state -> state = fun state ->
            let state = run_procedures state in 
            match state with
                | ACC x :: c, e, s, d ->
                    aux (c, e, (Env.find e x ) :: s, d)

                | CST b :: c, e, s, d -> 
                    aux (c, e, `CST b :: s, d)

                | CLS (x, c', k) :: c, e, s, d ->
                    aux (c, e, `CLS (x, c', Env.copy e, k, Static) :: s, d)
                
                | RCL (f, x, c', k) :: c, e, s, d ->
                    let e' = Env.copy e in
                    let () = Env.replace e' f @@ `CLS (x, c', e', k, Static) in
                    aux (c, e, `CLS (x, c', e', k, Static) :: s, d)

                | LER f :: c, e, v :: s, d -> 
                    let () = Env.replace e f v in
                    aux (c, e, s, d)

                | TYP k :: c, e, s, d ->
                    aux (c, e, `TYP k :: s, d)

                | APP :: c, e,  v :: `CLS (x, c', e', _, Static) :: s, d ->
                    let () = Env.replace e' x v in
                    aux (c', e', s, Frame (c, e) :: d)

                | APP :: c, e,  v :: `CLS (x, c', e', ((t1, t2) as k), Strict) :: s, d ->
                    let t' = result t1 (typeof_stack_value v) in
                    aux (CAS :: APP :: CAS :: c, e, 
                        v :: `TYP (t2, dom t2) :: `CLS (x, c', e', k, Static) :: `TYP (t', dom t') :: s, d)

                | TAP :: _, _,  v :: `CLS (x, c', e', _, Static) :: s, d ->
                    let () = Env.replace e' x v in
                    aux (c', e', s, d)

                | TAP :: c, e,  v :: `CLS (x, c', e', ((t1,t2) as k), Strict) :: s, d ->
                    let t = result t1 (typeof_stack_value v) in
                    aux (CAS :: TCA (t,dom t) :: c, e, v :: `TYP (t2,dom t2) :: `CLS (x, c', e', k, Static) :: s, d)

                | RET :: c, e, v :: s, Boundary k :: d ->
                    aux (CAS :: RET :: c, e, v :: `TYP k :: s, d) 
                
                | RET :: _, _, v :: s, Frame (c', e') :: d ->
                    aux (c', e', v :: s, d)

                (* this shouldn't happen as creating a fail terminates execution *)
                (* | (TAP|APP|TCA _) :: c, e,  (`FAIL :: _ :: s | _ :: `FAIL :: s), d -> 
                    aux ([], empty, `FAIL :: s, Frame (c, e) :: d) *)

                | TCA k::_, _, v::`CLS (x,c',e',_,Static)::s, d ->
                    let () = Env.replace e' x v in
                    aux (c', e', s, dump k d)

                | TCA k :: c, e, v :: `CLS (x,c',e',(t1, t2), Strict) :: s, d ->
                    let t = result t1 (typeof_stack_value v) in
                    let domt = dom t in
                    aux (CAS::TCA (compose k (t, domt)):: c, e, v::`TYP (t2,dom t2)::`CLS (x,c',e',k,Static) :: s, d)

                | CAS :: c, e, `CST b :: `TYP (t,_) :: s, d ->
                    if subtype (constant b) (ceil t) 
                    then aux (c, e, `CST b :: s, d)
                    else aux ([], empty, `FAIL :: s, Frame (c, e) :: d)
                    
                | CAS :: c, e, `CLS (x, c', e', (t1,t2), _) :: `TYP (t1',t2') :: s, d ->
                    if is_bottom t2' then 
                    aux ([], empty, `FAIL :: s, Frame (c, e) :: d)
                    else
                    (* let () = print_endline "debug time" in
                    let () = print_endline (pp_tau t1) in
                    let () = print_endline (pp_tau t1') in
                    let () = print_endline (pp_tau (cap t1 t1')) in
                    let () = print_endline (pp_tau (cup t1 t1')) in *)
                    let k = (cap t1 t1', cap t2 t2') in
                    aux (c, e, `CLS (x, c', e', k, Strict) :: s, d)

                | LET x :: c, e, v :: s, d ->
                    let () = Env.add e x v  in
                    aux (c, e, s, d)
                
                | END x :: c, e, s, d ->
                    let () = Env.remove e x in
                    aux (c, e, s, d)

                | MKP :: c, e, v2 :: v1 :: s, d ->
                    aux (c, e, `PAIR (v1, v2) :: s, d)

                | FST :: c, e, `PAIR (v1, _) :: s, d -> 
                    aux (c, e, v1 :: s, d)
              
                | SND :: c, e, `PAIR (_, v2) :: s, d ->
                    aux (c, e, v2 :: s, d)

                | SUC :: c, e, `CST (Integer i) :: s, d ->
                    aux (c, e, `CST (Integer (succ i)) :: s, d)

                | PRE :: c, e, `CST (Integer i) :: s, d ->
                    aux (c, e, `CST (Integer (pred i)) :: s, d)

                | MUL :: c, e, `CST (Integer i1) :: `CST (Integer i2) :: s, d ->
                    aux (c, e, `CST (Integer (mult i1 i2)) :: s, d)

                | EQB :: c, e, `CST (Integer i1) :: `CST (Integer i2) :: s, d ->
                    let ieq = if i1 = i2 then zero else one in
                    aux (c, e, `CST ieq :: s, d)

                | ADD :: c, e, `CST (Integer i1) :: `CST (Integer i2) :: s, d ->
                    aux (c, e, `CST (Integer (add i1 i2)) :: s, d) 
                
                | SUB :: c, e, `CST (Integer i1) :: `CST (Integer i2) :: s, d ->
                    aux (c, e, `CST (Integer (sub i2 i1)) :: s, d) 

                | IFZ (c1, _) :: c, e, `CST b :: s, d 
                    when b = Primitives.zero ->
                    aux (c1 @ c, e, s, d)

                | IFZ (_, c2) :: c, e, _ :: s, d ->
                    aux (c2 @ c, e, s, d)

                | s -> s

            in aux (code, env, [], [])
    
        (* let print_value : stack_value -> unit = function
            | `CST c -> Print.print_e (Cst c)
            | `BTC _ | `ENV _ -> failwith "wrong type of return value on stack"
            | `CLS (x,_,_,_) -> Printf.printf "fun %s -> code and env" (Print.pp_var x)
            | `TYP t -> pp_tau t *)


    end

    open Transitions
    open MetricsDebug
    open Print

        
    let run_init code =
        let () = if !(run_params.debug) then print_endline "Run initialization" in
        run code @@ Env.create 20

    let finish = function 
        | _, _, [v], _ -> v
        | _, _, _ :: _ :: _, _ -> failwith "unfinished computation"
        | _ -> failwith "no return value"


    let wrap_run : bytecode -> parameters_structure -> unit = 
        fun code params ->
            begin 
            run_params.debug := !(params.debug);
            run_params.verbose := !(params.verbose);
            run_params.step_mode := !(params.step_mode);
            run_params.monitor := !(params.monitor);
            run_params.step_start := !(params.step_start)
            end;
            let v = finish (run_init code) in
            let () = 
                print_string "- " ; print_string @@ show_result v; print_endline ""
            in if !(params.monitor) then
                begin
                print_endline "\n===Monitor===\n=============\n";
                let met = run_params.metrics in
                let (step_max, size_max) = max cmp_tuple met.stack_sizes in
                Printf.printf "Stack max size:               %s at step %s\n" 
                (string_of_int size_max) (string_of_int step_max);
                let (step_max, size_max) = max cmp_tuple met.dump_sizes in
                Printf.printf "Control stack max size:       %s at step %s\n" 
                (string_of_int size_max) (string_of_int step_max);
                let (step_max, size_max) = max cmp_tuple met.longest_proxies in
                Printf.printf "Longest proxy size:           %s at step %s\n" 
                (string_of_int size_max) (string_of_int step_max);
                let (step_max, size_max) = max cmp_tuple met.casts in
                Printf.printf "Largest amount of casts size: %s at step %s\n" 
                (string_of_int size_max) (string_of_int step_max);
                let (step_max, size_max) = max cmp_tuple met.env_sizes in
                Printf.printf "Env max size: %s at step %s\n" 
                (string_of_int size_max) (string_of_int step_max);
                let instr_counts = met.instructions in
                let l_instr_counts = List.of_seq (MetricsEnv.to_seq instr_counts) in
                List.iter (fun (by, cnt) ->
                        printf "\n%i     %s" cnt (show_byte 0 by)) l_instr_counts;
                print_endline "\n=============\n=============";
                run_params.metrics <- init_metrics ()
                end

end