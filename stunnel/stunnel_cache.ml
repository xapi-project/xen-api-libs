(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

(** Operate a small cache of stunnels so we can re-use them for repeated calls *)

(* Caveats:
   * stunnel donators should only donate stunnels which they knows are connected
     to the main HTTP request loop in the server -- HTTP 1.1 should be used and 
     the connection should be kept-alive
 *)

module D=Debug.Debugger(struct let name="stunnel_cache" end)
open D

type endpoint = { host: string; port: int }

(* Need to limit the absolute number of stunnels as well as the maximum age *)
let max_stunnel = 22
let max_age = 180. *. 60. (* seconds *)
let max_idle = 5. *. 60. (* seconds *)

(* The add function adds the new stunnel before doing gc, so the cache *)
(* can briefly contain one more than maximum. *)
let capacity = max_stunnel + 1

(** An index of endpoints to stunnel IDs *)
let index : (endpoint, int list) Hashtbl.t ref = ref (Hashtbl.create capacity)
(** A mapping of stunnel unique IDs to donation times *)
let times : (int, float) Hashtbl.t ref = ref (Hashtbl.create capacity)
(** A mapping of stunnel unique ID to Stunnel.t *)
let stunnels : (int, Stunnel.t) Hashtbl.t ref = ref (Hashtbl.create capacity)

open Pervasiveext
open Threadext
open Listext

let m = Mutex.create ()

let id_of_stunnel stunnel = 
    Opt.default "unknown" (Opt.map string_of_int stunnel.Stunnel.unique_id)

let unlocked_gc () = 
  let now = Unix.gettimeofday () in
  let string_of_id id = 
    let stunnel = Hashtbl.find !stunnels id in
    Printf.sprintf "(id %s / idle %.2f age %.2f)" 
      (id_of_stunnel stunnel)
      (now -. (Hashtbl.find !times id))
      (now -. stunnel.Stunnel.connected_time) in
  let string_of_endpoint ep = Printf.sprintf "%s:%d" ep.host ep.port in
  let string_of_index ep xs = Printf.sprintf "[ %s %s ]" (string_of_endpoint ep) (String.concat "; " (List.map string_of_id xs)) in
  debug "Cache contents: %s" (Hashtbl.fold (fun ep xs acc -> string_of_index ep xs ^ " " ^ acc) !index "");

  let all_ids = Hashtbl.fold (fun k _ acc -> k :: acc) !stunnels [] in

  let to_gc = ref [] in
  (* Find the ones which are too old *)
  let now = Unix.gettimeofday () in
  Hashtbl.iter
    (fun idx stunnel ->
       let time = Hashtbl.find !times idx in
       let idle = now -. time in
       let age = now -. stunnel.Stunnel.connected_time in
       if age > max_age then begin
	 debug "Expiring stunnel id %s; age (%.2f) > limit (%.2f)" (id_of_stunnel stunnel) age max_age;
	 to_gc := idx :: !to_gc
       end else if idle > max_idle then begin
	 debug "Expiring stunnel id %s; idle (%.2f) > limit (%.2f)" (id_of_stunnel stunnel) age max_idle;
	 to_gc := idx :: !to_gc
       end) !stunnels;
  let num_remaining = List.length all_ids - (List.length !to_gc) in
  if num_remaining > max_stunnel then begin
    let times' = Hashtbl.fold (fun k v acc -> (k, v) :: acc) !times [] in
    let times' = List.filter (fun (idx, _) -> not(List.mem idx !to_gc)) times' in
    (* Sort into descending order of donation time, ie youngest first *)
    let times' = List.sort (fun x y -> compare (fst y) (fst x)) times' in
    let youngest, oldest = List.chop max_stunnel times' in
    let oldest_ids = List.map fst oldest in
    List.iter
      (fun x -> 
	 let stunnel = Hashtbl.find !stunnels x in
	 debug "Expiring stunnel id %s since we have too many cached tunnels (limit is %d)" 
	   (id_of_stunnel stunnel) max_stunnel) oldest_ids;
    to_gc := !to_gc @ oldest_ids
  end;
  (* Disconnect all stunnels we wish to GC *)
  List.iter (fun id ->
	       let s = Hashtbl.find !stunnels id in
	       Stunnel.disconnect s) !to_gc;
  (* Remove all reference to them from our cache hashtables *)
  let index' = Hashtbl.create capacity in
  Hashtbl.iter
    (fun ep ids ->
      let kept_ids = (List.filter (fun id -> not(List.mem id !to_gc)) ids) in
      if kept_ids != [] then Hashtbl.add index' ep kept_ids
      else ()
    ) !index;
  let times' = Hashtbl.copy !times in
  List.iter (fun idx -> Hashtbl.remove times' idx) !to_gc;
  let stunnels' = Hashtbl.copy !stunnels in
  List.iter (fun idx -> Hashtbl.remove stunnels' idx) !to_gc;

  index := index';
  times := times';
  stunnels := stunnels'

let gc () = Mutex.execute m unlocked_gc

let counter = ref 0

let add (x: Stunnel.t) = 
  let now = Unix.gettimeofday () in
  Mutex.execute m
    (fun () ->
       let idx = !counter in
       incr counter;
       Hashtbl.add !times idx now;
       Hashtbl.add !stunnels idx x;
       let ep = { host = x.Stunnel.host; port = x.Stunnel.port } in
       let existing = 
	 if Hashtbl.mem !index ep
	 then Hashtbl.find !index ep
	 else [] in
       Hashtbl.replace !index ep (idx :: existing);
       debug "Adding stunnel id %s (idle %.2f) to the cache"
	     (id_of_stunnel x) 0.;
       unlocked_gc ()
    )
  
(** Returns an Stunnel.t for this endpoint (oldest first), raising Not_found
    if none can be found *)
let remove host port = 
  let ep = { host = host; port = port } in
  Mutex.execute m
    (fun () ->
       unlocked_gc ();

       let ids = Hashtbl.find !index ep in
       let table = List.map (fun id -> id, Hashtbl.find !times id) ids in
       let sorted = List.sort (fun a b -> compare (snd a) (snd b)) table in
       match sorted with
       | (id, time) :: _ ->
	   let stunnel = Hashtbl.find !stunnels id in
	   debug "Removing stunnel id %s (idle %.2f) from the cache"
	     (id_of_stunnel stunnel) (Unix.gettimeofday () -. time);
	   let stunnel = Hashtbl.find !stunnels id in
	   Hashtbl.remove !stunnels id;
	   Hashtbl.remove !times id;
	   Hashtbl.replace !index ep (List.filter (fun x -> x <> id) ids);
	   stunnel
       | _ -> raise Not_found
    )

(** Flush the cache - remove everything *)
let flush () =
  Mutex.execute m 
    (fun () ->
      info "Flushing cache";
      Hashtbl.iter (fun id st -> Stunnel.disconnect st) !stunnels;
      Hashtbl.clear !stunnels;
      Hashtbl.clear !times;
      Hashtbl.clear !index;
      info "Flushed!")


let connect ?use_fork_exec_helper ?write_to_log host port =
  try
    remove host port
  with Not_found ->
    error "Failed to find stunnel in cache for endpoint %s:%d" host port;
    Stunnel.connect ?use_fork_exec_helper ?write_to_log host port
    
