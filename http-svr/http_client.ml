(*
 * Copyright (C) 2006-2010 Citrix Systems Inc.
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
(* A very simple HTTP client *)

open Stringext

module D = Debug.Debugger(struct let name="http" end)
open D

exception Connection_reset

(** Thrown when no data is received from the remote HTTP server. This could happen if
    (eg) an stunnel accepted the connection but xapi refused the forward causing stunnel
    to immediately close. *)
exception Empty_response_from_server

(** Thrown when we get a non-HTTP response *)
exception Http_request_rejected of string

(** Thrown when we get a specific HTTP failure *)
exception Http_error of string * string

(** Thrown when we fail to parse a particular part of the HTTP message *)
exception Parse_error of string

let http_rpc_send_query fd request =
	try
		Unixext.really_write_string fd (Http.Request.to_wire_string request)
	with
	| Unix.Unix_error(Unix.ECONNRESET, _, _) -> raise Connection_reset

(* Internal exception thrown when reading a newline-terminated HTTP header when the 
   connection is closed *)
exception Http_header_truncated of string

(* Tediously read an HTTP header byte-by-byte. At some point we need to add buffering
   but we'll need to encapsulate our file descriptor into more of a channel-like object
   to make that work. *)
let input_line_fd (fd: Unix.file_descr) = 
	let buf = Buffer.create 20 in
	let finished = ref false in
	try
		while not(!finished) do
			let buffer = " " in
			let read = Unix.read fd buffer 0 1 in
			if read = 1 then begin
				if buffer = "\n"
				then finished := true
				else Buffer.add_char buf buffer.[0]
			end else begin
				if Buffer.contents buf = ""
				then finished := true
				else raise (Http_header_truncated (Buffer.contents buf));
			end
		done;
		Buffer.contents buf
	with
	| Unix.Unix_error(Unix.ECONNRESET, _, _) -> raise Connection_reset

(** [response_of_fd_exn fd] returns an Http.Response.t object, or throws an exception *)
let response_of_fd_exn fd =
	let task_id = ref None in
	let content_length = ref None in

	(* Initial line has the response code on it *)
	let line = input_line_fd fd in
	match String.split_f String.isspace line with
		| http_version :: code :: rest ->
			let version = match String.split ~limit:2 '/' http_version with
				| [ "HTTP"; version ] -> version
				| _ ->
					error "Failed to parse HTTP response status line [%s]" line;
					raise (Parse_error (Printf.sprintf "Failed to parse %s" http_version)) in
			let message = String.concat " " rest in
			let end_of_headers = ref false in
			let headers = ref [] in
			while not !end_of_headers do
				let line = input_line_fd fd in
				(* NB input_line removes the final '\n'.
				   RFC1945 says to expect a '\r\n' (- '\n' = '\r') *)
				match line with       
					| "" | "\r" -> end_of_headers := true
					| x ->
						let k, v = match String.split ~limit:2 ':' x with
							| [ k; v ] -> String.lowercase k, String.strip String.isspace v
							| _        -> "", "" in
						if k = String.lowercase Http.Hdr.task_id then task_id := Some v
						else if k = String.lowercase Http.Hdr.content_length then content_length := Some (Int64.of_string v)
						else headers := (k, v) :: !headers
			done;
			{
				Http.Response.version = version;
				code = code;
				message = message;
				content_length = !content_length;
				task = !task_id;
				additional_headers = !headers;
				body = None;
			}
		| _ ->
			error "Failed to parse HTTP response status line [%s]" line;
			raise (Parse_error (Printf.sprintf "Expected initial header [%s]" line))

(** [response_of_fd fd] returns an optional Http.Response.t record *)
let response_of_fd fd =
	try
		Some (response_of_fd_exn fd)
	with _ -> None

(** See perftest/tests.ml *)
let last_content_length = ref 0L

let http_rpc_recv_response error_msg fd =
	match response_of_fd fd with
		| None -> raise (Http_request_rejected error_msg)
		| Some response ->
			begin match response.Http.Response.code with
				| ("401"|"403"|"500") as http_code -> raise (Http_error (http_code,error_msg))
				| "200" ->
					Opt.iter (fun x -> last_content_length := x) response.Http.Response.content_length;
					response
				| _ -> raise (Http_request_rejected error_msg)
			end

(** [rpc request f] marshals the HTTP request represented by [request] and [body]
    and then parses the response. On success, [f] is called with an HTTP response record.
    On failure an exception is thrown. *)
let rpc (fd: Unix.file_descr) request f =
	http_rpc_send_query fd request;
	f (http_rpc_recv_response (Http.Request.to_string request) fd) fd

