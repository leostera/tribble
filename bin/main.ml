open Eio.Std

module Scheduler = struct

  type t = {
    domains: unit Domain.t list;
  }

  let empty: t = { domains = [] }

  let __scheduler__ = ref empty

  let run_scheduler () = ()

  let init () = 
    let nproc = Domain.recommended_domain_count () in
    let domains = List.init nproc (fun i -> Domain.spawn (fun () -> run_scheduler ())) in
    __scheduler__ := { domains }

end


module Supervisor (B: Base) = struct
  type strategy =
    | One_for_all
    | One_for_one

  type 'child t = {
    pids: 'child list;
    strategy: strategy;
  }

  let make strategy = { pids=[]; strategy }
end

1. processes on miou -> across cores
2. messaging
3. monitor/linking
4. supervisor

root process
-> application supervisor
   -> database supervisors
      -> database connection pool supervisor
         -> database connection process
      -> database query handler supervisor
         -> database query process

----
scheduler
-> threads
  -> many processes

module Process = struct
  type 'msg t = { mailbox : 'msg Eio.Stream.t; is_alive : bool ref }

  let recv t () =
    Eio.Stream.take_nonblocking t.mailbox

  let send t msg = Eio.Stream.add t.mailbox msg

  let _is_alive t = !t.is_alive

  let spawn sw domain fn =
    let process = { mailbox = Eio.Stream.create max_int ; is_alive = ref true} in
    Fiber.fork ~sw (fun () ->
        Fiber.yield ();
        Eio.Domain_manager.run domain (fun () ->
            Fiber.yield ();
            fn ~recv:(recv process);
            process.is_alive := false;
            ));
    process
end

let rec loop ~recv env name count () =
  match recv () with
  | Some 2112 -> Eio.traceln "proc[%s]: dead at %d%!" name count
  | _ -> loop ~recv env name (count + 1) ()

let main ~env ~domain =
  Switch.run @@ fun sw ->
  Eio.traceln "\n";
  let pids =
    List.init 1_000_000 (fun i ->
        Process.spawn sw domain @@ fun ~recv ->
        loop ~recv env ("pid" ^ string_of_int i) 0 ())
  in
  Eio.traceln "spawned 1_000_000 processes";

  Process.send (List.nth pids (Random.int 230)) `kill;
  Process.send (List.nth pids (Random.int 230)) `kill;
  Process.send (List.nth pids (Random.int 230)) `kill;
  Process.send (List.nth pids (Random.int 230)) `kill;
  Process.send (List.nth pids (Random.int 230)) `kill;
  Process.send (List.nth pids (Random.int 230)) `kill;
  ()

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let domain = Eio.Stdenv.domain_mgr env in
  Scheduler.init ();
  main ~env ~domain
