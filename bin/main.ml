open Eio.Std

module Worker = struct
  type task = Fetch of Uri.t 

  let rec fetch (Fetch uri) =
    let open Cohttp_eio in

    let host = Uri.host uri in
    let path = Uri.path uri in
    let res, buf = Client.get env ?headers ~host path in
    let status = Http.Response.status res in
    match status with
    | `OK -> (res, buf) |> Client.read_fixed
    | `Permanent_redirect | `Moved_permanently | `Temporary_redirect | `Found ->
        let headers = Http.Response.headers res in
        let location = Http.Header.get headers "location" |> Option.get in
        fetch (Fetch {host; path})

  let handle_task ~env task =
    let body = fetch task 
    let _nodes = Soup.parse body in
    print_string body

  let rec loop ~env task_queue =
    let task, reply = Eio.Stream.take task_queue in
    let result = handle_task ~env task in
    Promise.resolve reply result;
    loop ~env task_queue

  let spawn ~env ~domain ~sw ~task_queue =
    Fiber.fork_daemon ~sw (fun () ->
        Eio.Domain_manager.run domain (fun () -> loop ~env task_queue))
end

let queue_task queue task =
  let reply, resolve = Promise.create () in
  Eio.Stream.add queue (task, resolve);
  Promise.await reply

let main ~env ~domain =
  Switch.run @@ fun sw ->
  let task_queue = Eio.Stream.create 0 in
  for _i = 1 to 10 do
    Worker.spawn ~env ~domain ~sw ~task_queue
  done;
  queue_task task_queue
    (Worker.Fetch
       {
         host = "github.com";
         path =
           "/leostera/caramel/blob/sugarcane/caramel/newcomp/sugarcane/pass_flatten_modules.ml";
       });
  ()

let () =
  Eio_main.run @@ fun env ->
  let domain = Eio.Stdenv.domain_mgr env in
  main ~env ~domain
