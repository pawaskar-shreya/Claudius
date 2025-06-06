(** Hello *)

(* https://wiki.osdev.org/PC_Screen_Font *)

type psfheader = {
  magic : int32;
  version : int32;
  headersize : int32;
  flags : int32;
  number_of_glyphs : int32;
  bytes_per_glyph : int32;
  height : int32;
  width : int32;
}

module Glyph = struct
  type t = { bitmap : bytes; width : int; height : int }

  let dimensions g = (g.width, g.height, 0, 0)
  let bitmap g = g.bitmap
end

type t = {
  header : psfheader;
  glyphs : bytes array;
  map : (Uchar.t * int) list;
}

type reader_t = int64 -> int -> Bytes.t -> unit

(* ----- internal ----- *)

let read_header (reader : reader_t) : (psfheader, string) result =
  let header_length = 4 * 8 in
  let header_buffer = Bytes.create header_length in
  try
    reader 0L header_length header_buffer;
    Result.ok
      {
        magic = Bytes.get_int32_le header_buffer 0;
        version = Bytes.get_int32_le header_buffer 4;
        headersize = Bytes.get_int32_le header_buffer 8;
        flags = Bytes.get_int32_le header_buffer 12;
        number_of_glyphs = Bytes.get_int32_le header_buffer 16;
        bytes_per_glyph = Bytes.get_int32_le header_buffer 20;
        height = Bytes.get_int32_le header_buffer 24;
        width = Bytes.get_int32_le header_buffer 28;
      }
  with Sys_error reason -> Result.error reason

let load_glyphs (reader : reader_t) header : (bytes array, string) result =
  let bpg = Int32.to_int header.bytes_per_glyph in
  try
    Result.ok
      (Array.init (Int32.to_int header.number_of_glyphs) (fun i ->
           let buffer = Bytes.create bpg in
           reader
             (Int64.of_int (Int32.to_int header.headersize + (i * bpg)))
             bpg buffer;
           buffer))
  with Sys_error reason -> Result.error reason

let inner_load_map_table reader header : ((Uchar.t * int) list, string) result =
  try
    let offset : int64 ref =
      ref
        (Int64.of_int
           (Int32.to_int header.headersize
           + Int32.to_int header.number_of_glyphs
             * Int32.to_int header.bytes_per_glyph))
    in
    let rec outerloop (counter : int) (tail : (Uchar.t * int) list list) :
        (Uchar.t * int) list list =
      let rec find_next_terminator (sofar : char list) : char list option =
        try
          let buffer = Bytes.create 1 in
          reader !offset 1 buffer;
          offset := Int64.add !offset 1L;
          let c = Bytes.get buffer 0 in
          match c with
          | '\255' -> Some sofar
          | _ -> find_next_terminator (c :: sofar)
        with
        | Invalid_argument _ -> None
        | Sys_error _ -> None
      in
      match find_next_terminator [] with
      | None -> tail
      | Some bytes_list ->
          let next_batch_list = List.rev bytes_list in
          let next_batch_buffer = Bytes.create (List.length next_batch_list) in
          List.iteri
            (fun i c -> Bytes.set next_batch_buffer i c)
            next_batch_list;

          let rec bytes_to_unicodes (offset : int) (tail : Uchar.t list) :
              Uchar.t list =
            let remaining = Bytes.length next_batch_buffer - offset in
            match remaining with
            | 0 -> tail
            | _ -> (
                let c = Bytes.get_utf_8_uchar next_batch_buffer offset in
                let size = Uchar.utf_decode_length c in
                match Uchar.utf_decode_is_valid c with
                | false -> bytes_to_unicodes (offset + size) tail
                | true ->
                    bytes_to_unicodes (offset + size)
                      (Uchar.utf_decode_uchar c :: tail))
          in
          let char_list = bytes_to_unicodes 0 [] in
          let this_uchars = List.map (fun c -> (c, counter)) char_list in
          outerloop (counter + 1) (this_uchars :: tail)
    in
    let rest = outerloop 0 [] in
    Result.ok (List.concat rest)
  with Sys_error reason -> Result.error reason

let load_map_table reader header : ((Uchar.t * int) list, string) result =
  let flags = Int32.to_int header.flags in
  match flags with
  | 0 ->
      Result.ok
        (List.init (Int32.to_int header.number_of_glyphs) (fun i ->
             (Uchar.of_int i, i)))
  | 1 -> inner_load_map_table reader header
  | _ -> Result.error (Printf.sprintf "Unrecognised header flag 0x%x" flags)

let ( >>= ) = Result.bind

let channel_reader inc : reader_t =
 fun offset length buffer ->
  In_channel.seek inc offset;
  match In_channel.really_input inc buffer 0 length with
  | Some () -> ()
  | None -> invalid_arg "failed to get bytes"

let bytes_reader inbuf : reader_t =
 fun offset length outbuf ->
  Bytes.blit inbuf (Int64.to_int offset) outbuf 0 length

let load_font reader =
  read_header reader >>= fun header ->
  load_glyphs reader header >>= fun glyphs ->
  load_map_table reader header >>= fun map -> Result.ok { header; glyphs; map }

(* ----- public ----- *)

let of_bytes data =
  let reader = bytes_reader data in
  load_font reader

let of_file filename =
  In_channel.with_open_bin filename (fun ic ->
      let reader = channel_reader ic in
      load_font reader)

let print_header (font : t) =
  let header = font.header in
  Printf.printf "Magic:            0x%08x\n"
    (Int32.to_int header.magic land 0xFFFFFFFF);
  Printf.printf "Version:          %d\n" (Int32.to_int header.version);
  Printf.printf "Header Size:      %d\n" (Int32.to_int header.headersize);
  Printf.printf "Flags:            0x%08x\n"
    (Int32.to_int header.flags land 0xFFFFFFFF);
  Printf.printf "Number of Glyphs: %d\n" (Int32.to_int header.number_of_glyphs);
  Printf.printf "Bytes per Glyph:  %d\n" (Int32.to_int header.bytes_per_glyph);
  Printf.printf "Width:            %d\n" (Int32.to_int header.width);
  Printf.printf "Height:           %d\n" (Int32.to_int header.height)

let glyph_count (font : t) : int = Int32.to_int font.header.number_of_glyphs

let glyph_of_char (font : t) (u : Uchar.t) : Glyph.t option =
  match List.assoc_opt u font.map with
  | None -> None
  | Some index -> (
      match index >= 0 && index < Array.length font.glyphs with
      | false -> None
      | true ->
          Some
            {
              bitmap = font.glyphs.(index);
              width = Int32.to_int font.header.width;
              height = Int32.to_int font.header.height;
            })
