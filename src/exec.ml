open Compile
open Primitives

module Exec1 = struct
    include Compile1
    open Bytecode1

    module Env = Map.Make(struct 
        type t = var
        let compare = Pervasives.compare end)

    type result = [
        | `CST of b
        | `Fail ]

    type stack_value = 
        [ `CST of b 
        | `BTC of bytecode 
        | `ENV of env
        | `CLS of var * bytecode ]
    and env = stack_value Env.t

    type stack = stack_value list

    type dump = env list (*wrong; todo*)

    type state = bytecode * env * stack * dump

    let run code env = 
        let rec aux : state -> state = function
            | CST b :: c, e, s, d -> 
                aux (c, e, `CST b :: s, d)

            | ACC x :: c, e, s, d ->
                aux (c, e, (Env.find x e) :: s, d)

            | CLS (x, c') :: c, e, s, d ->
                aux (c, e, `CLS (x,c') :: s, d)

            | APP :: c, e, `CLS (x,c') :: v :: s, d ->
                let e' = Env.add x v e in
                aux (c', e', `BTC c :: `ENV e :: s, d)

            | RET :: _, _, v :: `BTC c' :: `ENV e' :: s, d ->
                aux (c', e', v :: s, d)

            | SUC :: c, e, `CST (Integer i) :: s, d ->
                aux (c, e, `CST (Integer (succ i)) :: s, d)

            | PRE :: c, e, `CST (Integer i) :: s, d ->
                aux (c, e, `CST (Integer (pred i)) :: s, d)

            | s -> s

        in aux (code, env, [], [])
    
    let run_init code =
        run code Env.empty

    let finish = function 
        | _, _, v :: _, _ -> v
        | _ -> failwith "no return value"

    let print_value : stack_value -> unit = function
        | `CST c -> Print.print_e (Cst c)
        | `BTC _ | `ENV _ -> failwith "wrong type of return value on stack"
        | `CLS (x,_) -> Printf.printf "fun %s -> code" (Print.pprint_var x)

    let wrap_run code = 
        let v = finish (run_init code) in
        print_string "- " ; print_value v; print_endline ""
end