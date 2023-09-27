open Eio.Std

type task = Fetch of Uri.t

let ( let* ) = Result.bind

module Visited_urls = struct
  type t = { lock : Eio.Mutex.t; urls : (string, unit) Hashtbl.t }

  let _visited_urls : t =
    { lock = Eio.Mutex.create (); urls = Hashtbl.create 1024 }

  let is_visited (Fetch url) =
    Eio.traceln "Visited_urls.is_visited";
    Eio.Mutex.use_ro _visited_urls.lock (fun () ->
        Hashtbl.mem _visited_urls.urls (Uri.to_string url))

  let track (Fetch url) =
    Eio.traceln "Visited_urls.track";
    Eio.Mutex.use_rw ~protect:true _visited_urls.lock (fun () ->
        Hashtbl.add _visited_urls.urls (Uri.to_string url) ())
end

let queue_task queue task =
  if Visited_urls.is_visited task then ()
  else Eio.Stream.add queue task

module Worker = struct
  let config = Piaf.Config.{ default with follow_redirects = true }

  let fetch ~env (Fetch uri) =
    Printf.printf "fetching %s\n%!" (Uri.to_string uri);
    Switch.run @@ fun sw ->
    match Piaf.Client.Oneshot.get ~config env ~sw uri with
    | Error e -> failwith (Piaf.Error.to_string e)
    | Ok response when Piaf.Status.is_successful response.status ->
        Eio.traceln "<- response success";
        Piaf.Body.to_string response.body
    | Ok _response -> failwith "bad response"

  module Uri_set = Set.Make (Uri)

  let extract_links body (Fetch uri) =
    Printf.printf "extractingl inks %s\n%!" (Uri.to_string uri);
    let host = Uri.host uri |> Option.get in
    let open Soup in
    let links = parse body $$ "a" in
    links
    |> fold
         (fun acc link ->
           match attribute "href" link with
           | None -> acc
           | Some href ->
               let href = Uri.of_string href in
               let href_host = Uri.host_with_default ~default:host href in
               if href_host <> host then acc
               else
                 let href = Uri.with_host href (Some href_host) in
                 let href = Uri.with_scheme href (Uri.scheme uri) in
                 Uri_set.add href acc)
         Uri_set.empty
    |> Uri_set.to_list

  let handle_task ~env ~task_queue task =
    let* body = fetch ~env task in
    let links = extract_links body task in
    Printf.printf "found %d links\n%!" (List.length links);
    Visited_urls.track task;
    List.iter (fun link -> queue_task task_queue (Fetch link)) links;
    Eio.traceln "queued tasks";
    Ok ()

  let rec loop ~env task_queue =
    Eio.traceln "loop";
    let task = Eio.Stream.take task_queue in
    let _result = handle_task ~env ~task_queue task |> Result.get_ok in
    Eio.traceln "resolve";
    loop ~env task_queue

  let spawn ~env ~domain ~sw ~task_queue =
    Fiber.fork_daemon ~sw (fun () ->
        Eio.Domain_manager.run domain (fun () -> loop ~env task_queue))
end

let main ~env ~domain =
  Switch.run @@ fun sw ->
  let task_queue = Eio.Stream.create 0 in
  for _i = 0 to 10 do
    Worker.spawn ~env ~domain ~sw ~task_queue
  done;
  queue_task task_queue (Fetch (Uri.of_string "https://ocaml.org"));
  let clock = Eio.Stdenv.clock env in
  Eio.Time.sleep clock 100.0;
  ()

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let domain = Eio.Stdenv.domain_mgr env in
  main ~env ~domain
