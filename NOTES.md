
root url
-> fetch / extract links from here
-> collection urls
-> queue all of those

1. Domain
2. Domainslib <- higher level lib, Task (threadpool)
3. Lwt + Domains = </3 <- lwt_domains
   a) run Lwt promises on a main thread from a domain
   b) turn domain executing code into an Lwt promise
4. Eio + Cohttp(_eio) 


setup a pool of domains
-> queue a url
-> queue more urls


for domain in pool do
  domain.spawn (fun -> ... )
end


  let left = async pool (fun _ -> work pool fn s d) in
    (2) let left = async pool (fun _ -> work pool fn s d) in
      (3) let left = async pool (fun _ -> work pool fn s d) in
        if e - s < chunk_size then
        let i = ref s in
        while !i <= e && Option.is_none (Atomic.get found) do
          begin match fn !i with
            | None -> ()
            | Some _ as some -> Atomic.set found some
          end;
          incr i;
        done
        ...
      work pool fn (d+1) e;
      await (3)
    work pool fn (d+1) e;
    await (2)
  work pool fn (d+1) e;
  await (1)

