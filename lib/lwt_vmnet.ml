(*
 * Copyright (c) 2014 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Sexplib.Conv

type mode = Vmnet.mode = Host_mode | Shared_mode with sexp

type error = Vmnet.error =
 | Failure
 | Mem_failure
 | Invalid_argument
 | Setup_incomplete
 | Invalid_access
 | Packet_too_big
 | Buffer_exhausted
 | Too_many_packets
 | Unknown of int with sexp

exception Error of error with sexp 

type t = {
  dev: Vmnet.t;
  waiters: unit Lwt.u Lwt_sequence.t sexp_opaque;
} with sexp_of

let mac {dev} = Vmnet.mac dev
let max_packet_size {dev} = Vmnet.max_packet_size dev

let wakeup_for_read t =
  match Lwt_sequence.take_opt_l t.waiters with
  | Some u -> Lwt.wakeup u ()
  | None -> ()

let wait_for_event t =
  Vmnet.set_event_handler t.dev;
  let rec loop () =
    Lwt_preemptive.detach Vmnet.wait_for_event t.dev
    >>= fun () ->
    wakeup_for_read t;
    loop ()
  in loop ()
   
let init ?(mode = Shared_mode) () =
  try_lwt 
    let dev = Vmnet.init ~mode () in
    let waiters = Lwt_sequence.create () in
    let t = { dev; waiters } in
    let _ = wait_for_event t in
    return t
  with Vmnet.Error err -> fail (Error err)

let rec read t c =
  try_lwt
    return (Vmnet.read t.dev c)
  with
  | Vmnet.Error err -> fail (Error err)
  | Vmnet.No_packets_waiting ->
      let th, u : (unit Lwt.t * unit Lwt.u) = Lwt.task () in
      let node = Lwt_sequence.add_r u t.waiters in
      Lwt.on_cancel th (fun _ -> Lwt_sequence.remove node);
      th >>= fun () ->
      read t c

let write t c =
  try
    Vmnet.write t.dev c;
    return_unit
  with
  | Vmnet.Error err -> fail (Error err)
