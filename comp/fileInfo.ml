type fileinfo =
  { dirname   : string
  ; fileroot  : string
  ; ext       : string option
  }


let normalize_extension ext =
  let extlen = String.length ext in
  if extlen > 1 && ext.[0] = '.'
  then Some (String.sub ext 1 (extlen - 1))
  else if extlen = 0
       then None
       else Some ext
    
    
let chop_extension_if_any file =
  try
    Filename.chop_extension file
  with
  | Invalid_argument _ -> file
    
let get_extension_if_any file =
  let basename  = Filename.basename file in
  let basename' = chop_extension_if_any basename in
  let baselen   = String.length basename' in
  let ext       = String.sub basename baselen (String.length basename - baselen) in
  if String.length ext > 0
  then Some ext
  else None
    
let make_fileinfo file =
  { dirname  = Filename.dirname file
  ; fileroot = chop_extension_if_any (Filename.basename file)
  ; ext      = match get_extension_if_any file with
               | Some ext -> normalize_extension ext
               | None -> None
  }

let with_extension ext fileinfo =
  { fileinfo with ext = normalize_extension ext }

let with_fileroot root fileinfo =
  { fileinfo with fileroot = root }


let extension fileinfo  = fileinfo.ext
let fileroot  fileinfo  = fileinfo.fileroot
let basename  fileinfo  =
  let ext =
    match extension fileinfo with
    | Some ext -> "." ^ ext
    | None     -> ""
  in
  (fileroot fileinfo) ^ ext
let dirname   fileinfo  = fileinfo.dirname
let filename  fileinfo  = Filename.concat (fileinfo.dirname) (basename fileinfo)
