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
(*

  This module provides a facility to make XML-RPC/HTTPS requests to a remote
  server, and time out the request, killing the stunnel instance if needs be.
  It's used by the WLB code, but could be extended to be used elsewhere in the
  future, hopefully.

  There is a single request-handling thread, onto which requests are
  marshalled.  The thinking here is that there is little point sending
  multiple requests to the WLB server in parallel -- it's unlikely to respond
  any quicker, and this way we reduce the chance of DoS.

  Each request that comes in (on its own task-handling thread) queues the
  request onto the request-handling thread, and then launches a watcher
  thread to handle the timeout.

  If the timeout expires, then the stunnel instance handling the RPC is
  killed, to make cleanup quicker (i.e. to avoid waiting for the TCP timeout).
*)

open Printf
open Threadext

module D = Debug.Debugger(struct let name = "remote_requests" end)
open D

exception Timed_out
exception Internal_error

type response =
  | Success | Exception of exn | NoResponse

type queued_request = {
  task : API.ref_task;
  verify_cert : bool;
  host : string;
  port : int;
  headers : string list;
  body : string;
  handler : int -> string option -> Unix.file_descr -> unit;
  resp : response ref;
  resp_mutex : Mutex.t;
  resp_cond : Condition.t;
  enable_log : bool;
}

let make_queued_request task verify_cert host port headers body handler
    resp resp_mutex resp_cond enable_log =
  {
    task = task;
    verify_cert = verify_cert;
    host = host;
    port = port;
    headers = headers;
    body = body;
    handler = handler;
    resp = resp;
    resp_mutex = resp_mutex;
    resp_cond = resp_cond;
    enable_log = enable_log;
  }

let shutting_down = ref false
let request_queue : queued_request list ref = ref []
let request_mutex = Mutex.create()
let request_cond = Condition.create()

let kill_stunnel ~__context task =
  let pid = Int64.to_int (Db.Task.get_stunnelpid ~__context ~self:task) in
    if pid > 0 then
      begin
        debug "Killing stunnel pid: %d" pid;
        Helpers.log_exn_continue
          (sprintf "Remote request killing stunnel pid: %d" pid)
	  (fun () -> Unix.kill pid Sys.sigterm) ();
        Db.Task.set_stunnelpid ~__context ~self:task ~value:0L
      end

let signal_result' req result () =               
  if !(req.resp) = NoResponse then
    begin
      req.resp := result;
      Condition.signal req.resp_cond
    end

let signal_result req result =
  Mutex.execute req.resp_mutex (signal_result' req result)

let watcher_thread = function
  | (__context, timeout, delay, req) ->
      ignore (Delay.wait delay timeout);
      Mutex.execute req.resp_mutex
        (fun () ->
           if !(req.resp) = NoResponse then
             begin
               warn "Remote request timed out";
               kill_stunnel ~__context req.task;
               signal_result' req (Exception Timed_out) ()
             end)

let handle_request req =
  try
    Xmlrpcclient.do_secure_http_rpc ~task_id:(Ref.string_of req.task)
      ~verify_cert:req.verify_cert ~host:req.host ~port:req.port
      ~headers:req.headers ~body:req.body
      (fun content_length task_id s ->
         req.handler content_length task_id s;
         signal_result req Success)
  with
    | exn ->
        if req.enable_log then
          warn "Exception handling remote request %s: %s" req.body
            (ExnHelper.string_of_exn exn);
        signal_result req (Exception exn)

let handle_requests () =
  while Mutex.execute request_mutex (fun () -> not !shutting_down) do
    try
      let req =
        Mutex.execute request_mutex
          (fun () ->
             while !request_queue = [] do
               Condition.wait request_cond request_mutex;
             done;
             let q = !request_queue in
               request_queue := List.tl q;
               List.hd q)
      in
        handle_request req
    with
      | exn ->
          error "Exception in handle_requests thread!  %s"
            (ExnHelper.string_of_exn exn);
          Thread.delay 30.
  done

let start_watcher __context timeout delay req = 
  ignore (Thread.create watcher_thread (__context, timeout, delay, req))

let queue_request req =
  Mutex.execute request_mutex
    (fun () ->
       request_queue := req :: !request_queue;
       Condition.signal request_cond)

let perform_request ~__context ~timeout ~verify_cert ~host ~port
    ~headers ~body ~handler ~enable_log =
  let task = Context.get_task_id __context in
  let resp = ref NoResponse in
  let resp_mutex = Mutex.create() in
  let resp_cond = Condition.create() in
    Mutex.execute resp_mutex
      (fun () ->
         let delay = Delay.make () in
         let req =
           make_queued_request
             task verify_cert host port headers body handler
             resp resp_mutex resp_cond enable_log
         in
         start_watcher __context timeout delay req;
         queue_request req;

         Condition.wait resp_cond resp_mutex;
         Delay.signal delay;

         match !resp with
           | Success ->
               ()
           | Exception exn ->
               raise exn
           | NoResponse ->
               error "No response in perform_request!";
               raise Internal_error)

let stop_request_thread () =
  Mutex.execute request_mutex
    (fun () ->
       shutting_down := true;
       Condition.signal request_cond)

let read_response result content_length task_id s =
  try
    result := Unixext.string_of_fd s
  with
    | Unix.Unix_error(Unix.ECONNRESET, _, _) ->
        raise Xmlrpcclient.Connection_reset

let test_post_headers host len =
  Xapi_http.http_request Http.Post host "/" ~keep_alive:false @
    ["Content-Length: " ^ (string_of_int len)]

let send_test_post ~__context ~host ~port ~body =
  try
    let result = ref "" in
    let headers = test_post_headers host (String.length body) in
      perform_request ~__context ~timeout:30.0 ~verify_cert:true
        ~host ~port:(Int64.to_int port) ~headers ~body
        ~handler:(read_response result) ~enable_log:true;
      !result
  with
    | Timed_out ->
        raise (Api_errors.Server_error
                 (Api_errors.wlb_timeout, ["30.0"]))
    | Stunnel.Stunnel_verify_error reason ->
        raise (Api_errors.Server_error
                 (Api_errors.ssl_verify_error, [reason]))
