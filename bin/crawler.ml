open Eio.Std

type task = Fetch of Uri.t

let task_to_string (Fetch uri) = "Fetch(" ^ Uri.to_string uri ^ ")"
let ( let* ) = Result.bind

module Visited_urls = struct
  type t = { lock : Eio.Mutex.t; urls : (string, unit) Hashtbl.t }

  let _visited_urls : t =
    { lock = Eio.Mutex.create (); urls = Hashtbl.create 1024 }

  let is_visited (Fetch url) =
    Eio.Mutex.use_ro _visited_urls.lock (fun () ->
        Hashtbl.mem _visited_urls.urls (Uri.to_string url))

  let track (Fetch url) =
    Eio.Mutex.use_rw ~protect:true _visited_urls.lock @@ fun () ->
    Hashtbl.add _visited_urls.urls (Uri.to_string url) ()
end

let queue_task queue task =
  if Visited_urls.is_visited task then ()
  else Eio.traceln "queue_task %s" (task_to_string task);
  Eio.Stream.add queue task

module Worker = struct
  let config = Piaf.Config.{ default with follow_redirects = true }

  let fetch ~env (Fetch uri) =
    Printf.printf "-> fetching %s\n%!" (Uri.to_string uri);
    Switch.run @@ fun sw ->
    match Piaf.Client.Oneshot.get ~config env ~sw uri with
    | exception e -> Error (`piaf_exception e)
    | Error e -> Error (`fetch_error e)
    | Ok response when Piaf.Status.is_successful response.status ->
        Eio.traceln "<- response success";
        Piaf.Body.to_string response.body
    | Ok response ->
        Eio.traceln "<- response %s" (Piaf.Status.to_string response.status);
        Error (`bad_response response)

  module Uri_set = Set.Make (Uri)

  let should_fetch string =
    match string |> Filename.extension with "" | "html" -> true | _ -> false

  let extract_links body (Fetch uri) =
    Printf.printf "extracting links %s\n%!" (Uri.to_string uri);
    let host = Uri.host uri |> Option.get in
    let open Soup in
    match
      parse body $$ "a"
      |> fold
           (fun acc link ->
             match attribute "href" link with
             | Some raw_href when should_fetch raw_href ->
                 let is_relative = String.starts_with ~prefix:"../" raw_href in
                 let href = Uri.of_string raw_href in
                 let href_host = Uri.host_with_default ~default:host href in
                 if href_host <> host then acc
                 else
                   let href =
                     if is_relative then
                       let curr_path = uri |> Uri.path in
                       Uri.with_path uri (curr_path ^ "/" ^ raw_href)
                     else
                       let href = Uri.with_host href (Some href_host) in
                       let href = Uri.with_scheme href (Uri.scheme uri) in
                       href
                   in
                   Uri_set.add href acc
             | _ -> acc)
           Uri_set.empty
      |> Uri_set.to_list
    with
    | exception e ->
        Eio.traceln "something went wrong: %s" (Printexc.to_string e);
        []
    | links -> links

  let handle_task ~env ~task_queue task =
    let* body = fetch ~env task in
    let links = extract_links body task in
    Visited_urls.track task;
    Printf.printf "found %d links\n%!" (List.length links);
    List.iter
      (fun link ->
        queue_task task_queue (Fetch link);
        Eio.traceln "add to queue")
      links;
    Eio.traceln "queued tasks";
    Ok ()

  let rec loop ~env task_queue =
    Eio.traceln "loop";
    let task = Eio.Stream.take task_queue in
    match handle_task ~env ~task_queue task with
    | Ok () -> loop ~env task_queue
    | Error (`piaf_exception e) | Error (`Exn e) ->
        Eio.traceln "Unhandled exception: %s" (Printexc.to_string e);
        ()
    | Error (`fetch_error _)
    | Error `Bad_gateway
    | Error `Bad_request
    | Error (`Connect_error _)
    | Error `Internal_server_error
    | Error (`Invalid_response_body_length _)
    | Error (`Malformed_response _)
    | Error (`Msg _)
    | Error (`Protocol_error _)
    | Error (`TLS_error _)
    | Error `Upgrade_not_supported
    | Error (`bad_response _) ->
        Eio.traceln "Something went wrong";
        ()

  let spawn ~env ~domain ~sw ~task_queue =
    Fiber.fork_daemon ~sw (fun () ->
        Eio.Domain_manager.run domain (fun () ->
            loop ~env task_queue;
            `Stop_daemon))
end

let main ~env ~domain =
  Switch.run @@ fun sw ->
  let task_queue = Eio.Stream.create max_int in
  for _i = 0 to 19 do
    Worker.spawn ~env ~domain ~sw ~task_queue
  done;
  queue_task task_queue (Fetch (Uri.of_string "https://ocaml.org"));
  Eio.Time.sleep (Eio.Stdenv.clock env) 1.0;
  while not (Eio.Stream.is_empty task_queue) do
    Eio.Time.sleep (Eio.Stdenv.clock env) 0.01
  done;
  Eio.traceln "done";
  ()

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let domain = Eio.Stdenv.domain_mgr env in
  main ~env ~domain
