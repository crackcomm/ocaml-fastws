(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf

open Core
open Async

open Fastws

let src = Logs.Src.create "fastws.async"
module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

type t =
  | Header of Fastws.t
  | Payload of Bigstring.t
[@@deriving sexp_of]

let is_header = function Header _ -> true | _ -> false

let pp_client_connection_error ppf (e : Client_connection.error) =
  match e with
  | `Exn e ->
    Format.fprintf ppf "Exception %a" Exn.pp e
  | `Invalid_response_body_length resp ->
    Format.fprintf ppf "Invalid response body length %a" Response.pp_hum resp
  | `Malformed_response msg ->
    Format.fprintf ppf "Malformed response %s" msg

let write_frame w { header ; payload } =
  Pipe.write w (Header header) >>= fun () ->
  match payload with
  | None -> Deferred.unit
  | Some payload -> Pipe.write w (Payload payload)

let merge_headers h1 h2 =
  Headers.fold ~init:h2 ~f:begin fun k v a ->
    Headers.add_unless_exists a k v
  end h1

let response_handler iv nonce crypto r _body =
  let module Crypto = (val crypto : CRYPTO) in
  Log.debug (fun m -> m "%a" Response.pp_hum r) ;
  let upgrade_hdr = Option.map ~f:String.lowercase (Headers.get r.headers "upgrade") in
  let sec_ws_accept_hdr = Headers.get r.headers "sec-websocket-accept" in
  let expected_sec =
    Base64.encode_exn (Crypto.(sha_1 (of_string (nonce ^ websocket_uuid)) |> to_string)) in
  match r.version, r.status, upgrade_hdr, sec_ws_accept_hdr with
  | { major = 1 ; minor = 1 }, `Switching_protocols,
    Some "websocket", Some v when v = expected_sec ->
    Ivar.fill_if_empty iv (Ok r)
  | _ ->
    Log.err (fun m -> m "Invalid response %a" Response.pp_hum r) ;
    Ivar.fill_if_empty iv (Format.kasprintf Or_error.error_string "%a" Response.pp_hum r)

let write_iovec w iovec =
  List.fold_left iovec ~init:0 ~f:begin fun a { Faraday.buffer ; off ; len } ->
    Writer.write_bigstring w buffer ~pos:off ~len ;
    a+len
  end

let rec flush_req conn w =
  match Client_connection.next_write_operation conn with
  | `Write iovec ->
    let nb_read = write_iovec w iovec in
    Client_connection.report_write_result conn (`Ok nb_read) ;
    flush_req conn w
  | `Yield ->
    Client_connection.yield_writer conn (fun () -> flush_req conn w) ;
  | `Close _ -> ()

let rec read_response conn r =
  match Client_connection.next_read_operation conn with
  | `Close -> Deferred.unit
  | `Read -> begin
      Reader.read_one_chunk_at_a_time r
        ~handle_chunk:begin fun buf ~pos ~len ->
          let nb_read = Client_connection.read conn buf ~off:pos ~len in
          return (`Stop_consumed ((), nb_read))
        end >>= function
      | `Eof
      | `Eof_with_unconsumed_data _ -> raise Exit
      | `Stopped () -> read_response conn r
    end

let rec flush stream w =
  match Faraday.operation stream with
  | `Close -> raise Exit
  | `Yield -> Deferred.unit
  | `Writev iovec ->
    let nb_read = write_iovec w iovec in
    Faraday.shift stream nb_read ;
    flush stream w

let mk_client_write ?(stream=Faraday.create 4096) w =
  let rec inner r hdr =
    Pipe.read r >>= function
    | `Eof -> Deferred.unit
    | `Ok (Header t) ->
      let mask = Crypto.(to_string (generate 4)) in
      let h = { t with mask = Some mask } in
      serialize stream h ;
      flush stream w >>= fun () ->
      Log_async.debug (fun m -> m "-> %a" pp t) >>= fun () ->
      inner r (Some h)
    | `Ok (Payload buf) ->
      match hdr with
      | Some { mask = Some mask ; _ } ->
        xormask ~mask buf ;
        Faraday.write_bigstring stream buf ;
        xormask ~mask buf ;
        flush stream w >>= fun () ->
        inner r hdr
      | _ -> failwith "current header must exist" in
  Pipe.create_writer begin fun r ->
    if Writer.is_closed w then Deferred.unit
    else inner r None
  end

let need = function
  | 0 -> `Need_unknown
  | n -> `Need n

let handle_chunk w =
  let len_to_read = ref 0 in
  fun buf ~pos ~len ->
    let read_max already_read =
      let will_read = min (len - already_read) !len_to_read in
      len_to_read := !len_to_read - will_read ;
      let payload = Bigstring.sub_shared buf
          ~pos:(pos+already_read) ~len:will_read in
      Pipe.write_if_open w (Payload payload) >>= fun () ->
      return (`Consumed (already_read + will_read, need !len_to_read)) in
    if !len_to_read > 0 then read_max 0 else
      match parse buf ~pos ~len with
      | `More n -> return (`Consumed (0, `Need (len + n)))
      | `Ok (t, read) ->
        Log_async.debug (fun m -> m "<- %a" pp t) >>= fun () ->
        Pipe.write_if_open w (Header t) >>= fun () ->
        len_to_read := t.length ;
        if read < len && t.length > 0 then read_max read
        else
          return (`Consumed (read, `Need_unknown))

let mk_client_read r =
  Pipe.create_reader ~close_on_exception:false begin fun w ->
    let handle_chunk = handle_chunk w in
    Reader.read_one_chunk_at_a_time r ~handle_chunk >>| fun _ ->
    Pipe.close w
  end

let initialize ?timeout ?(extra_headers=Headers.empty) url r w =
  let nonce = Base64.encode_exn Crypto.(generate 16 |> to_string) in
  let headers = Option.value_map (Uri.host url)
      ~default:Headers.empty ~f:(Headers.add extra_headers "Host") in
  let headers = merge_headers headers (Fastws.headers nonce) in
  let req = Request.create ~headers `GET (Uri.path_and_query url) in
  let ok = Ivar.create () in
  let error_handler e =
    Ivar.fill ok (Format.kasprintf Or_error.error_string "%a" pp_client_connection_error e) in
  let response_handler = response_handler ok nonce (module Crypto) in
  let _body, conn =
    Client_connection.request req ~error_handler ~response_handler in
  flush_req conn w ;
  don't_wait_for (read_response conn r) ;
  Log_async.debug (fun m -> m "%a" Request.pp_hum req) >>= fun () ->
  let timeout = match timeout with
    | None -> Deferred.never ()
    | Some timeout ->
      Clock.after timeout >>| fun () ->
      Format.kasprintf Or_error.error_string
        "Timeout %a" Time.Span.pp timeout in
  Deferred.any [ Ivar.read ok ; timeout ] >>= function
  | Error e -> Error.raise e
  | Ok v -> Deferred.return v

let connect
    ?version ?options ?socket ?buffer_age_limit
    ?interrupt ?reader_buffer_size ?writer_buffer_size
    ?timeout
    ?stream
    ?(crypto = (module Crypto : CRYPTO))
    ?extra_headers url =
  let module Crypto = (val crypto : CRYPTO) in
  Async_uri.connect
    ?version ?options ?socket ?buffer_age_limit
    ?interrupt ?reader_buffer_size ?writer_buffer_size ?timeout
    url >>= fun (_sock, _conn, r, w) ->
  initialize ?timeout ?extra_headers url r w >>| fun _resp ->
  let client_read  = mk_client_read r in
  let client_write = mk_client_write ?stream w in
  don't_wait_for (Deferred.all_unit Pipe.[closed client_read; closed client_write] >>= fun () ->
                  Writer.close w >>= fun () ->
                  Reader.close r) ;
  client_read, client_write
