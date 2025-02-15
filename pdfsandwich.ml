(*
	process OCR on a pdf file;
	requires:
		- tesseract [depending on imagemagick and ghostscript]
		- unpaper
		- hocr2pdf (from ExactImage)
	
	(C) 2010-2018 Tobias Elze, modified for tesseract Heinrich Schwietering 2012
	patch for -rgb option contributed by James Cort
	patch for a parallel computing problem with Tesseract 4, Dominique Meeus, 2018
*)

include Pdfsandwich_version;;		(*provides string variable pdfsandwich_version*)

(*generate global temporary directory:*)
let global_temp_dir = Filename.temp_file "pdfsandwich_tmp" "";;

(*default binary names:*)
let unpaper = ref "unpaper";;
let identify = ref "identify";;
let convert = ref "convert";;
let tesseract = ref "tesseract";;	(* this will be preceded by the OMP_THREAD_LIMIT (see options) *)
let pdfinfo = ref "pdfinfo";;
let pdfunite = ref "pdfunite";;
let hocr2pdf = ref "hocr2pdf";;
let gs = ref "gs";;

(*global flags:*)
let verbose = ref false;;
let quiet = ref false;;

(*print output, if verbose option is set (default)*)
let pr s =
	if not !quiet then print_endline s
;;

let make_temp_file = Filename.temp_file ~temp_dir:global_temp_dir "pdfsandwich";;

(*execute command cmd and print it's invocation line (if verbose is set):*)
let run ?(crash=true) cmd =
	if !verbose then pr cmd;
	if Sys.command cmd <> 0 then
	(
		prerr_endline ("ERROR: Command \"" ^ cmd ^ "\" failed. ");
		if crash  then
		(
			prerr_endline ("Terminating pdfsandwich. All temporary files are kept.");
			exit 2;
		)
	)
;;

(*check if binary bin exists (in search path):*)
let check_for_binary bin =
	try
	let in_ch = Unix.open_process_in ("which " ^ bin) in
	let s = input_line in_ch in
	if s = "" then failwith "";
	ignore (Unix.close_process_in in_ch);
	with _ -> failwith 
		("Could not find program " 
		^ bin 
		^ ". Make sure this program exists and can be found in your search path.\nUse command line options to specify a custom binary.")
;;

(*return number of pages of a PDF file; needs pdfinfo:*)
let number_of_pages filename =
	try
	let in_ch = Unix.open_process_in (!pdfinfo ^ " " ^ filename) in
	let rec read_pdfinfo () =
		let s = input_line in_ch in
		if Str.string_match (Str.regexp "Pages:[^0-9]+\\([0-9]+\\)") s 0 then
		(
			ignore (Unix.close_process_in in_ch);
			int_of_string (Str.matched_group 1 s);
		)
		else read_pdfinfo ()
	in
	read_pdfinfo ()
	with _ -> failwith ("Error: pdfinfo could not determine number of pages. Check the pdf input file.\n")
;;


(*return number of CPUs:*)
let number_of_cpus () =
	(*different code for different platforms;
	runtime OS detection:*)
	try
	(match Sys.os_type with
	| "Unix" ->
	(
		let scriptstring = 
			let p = Unix.open_process_in "uname" in
			let os = input_line p in
			ignore (Unix.close_process_in p);
			match os with 
			| "Linux" -> "cat /proc/cpuinfo | grep processor | awk '{a++} END {print a}'" 
			| _ -> "sysctl -n hw.ncpu"	(*works (at least) for Darwin, OpenBSD, and FreeBSD*)
			
		in
		let in_ch = Unix.open_process_in scriptstring in
		let numstr = input_line in_ch in
		ignore (Unix.close_process_in in_ch);
		int_of_string numstr;
	)
	| _ -> failwith "Not yet implemented for Non-Unix systems.")
	with _ -> 1
;;

(*process OCR on pdf file infile and save the results to outfile:*)
let process_ocr 
				infile 
				outfile 
				first_page last_page 
				resolution 
				rgb 
				gray
				nthreads 
				language 
				convertopts 
				tessopts 
				hocropts 
				preprocess 
				unpaperopts 
				debug 
				enforcehocr2pdf 
				page_width_height 
				maxpixels =
	let pages_to_process = last_page - first_page + 1 in
	(*let hocr_resolution = Str.global_replace (Str.regexp "^\\(.+\\)x.*$") "\\1" resolution in*)
	let hocr_resolution = Printf.sprintf "%i" resolution in
	if nthreads > 1 then
		pr ("\nParallel processing with " ^ (string_of_int nthreads) ^ " threads started.\nProcessing page order may differ from original page order.\n");
	
	let process_page (curr_page, pdfname) =
		let tmppicfile = make_temp_file (if rgb then ".ppm" else if gray then ".pgm" else ".pbm") in
		let tmptessinpfile = make_temp_file ".tif" in
		let tmpocrfile = make_temp_file "" in
		let tmpcolfigfile = make_temp_file "_col.png" in
		let tmprescaled_infile = make_temp_file "_rescaled.pdf" in
		let tmpunpaperfile = make_temp_file ("_unpaper" ^ (if rgb then ".ppm" else if gray then ".pgm" else ".pbm")) in
		if not !quiet then
			Printf.printf "Processing page %i.\n" curr_page;
		flush_all ();
		(*get original height and width:*)
		let (orig_height, orig_width) =
			try
			pr (!identify ^ " -format \"%w\\n%h\\n\" " ^ " \"" ^ infile ^ "[" ^ (string_of_int (curr_page-1)) ^ "]\" ");
			let in_ch = Unix.open_process_in
				(!identify ^ " -format \"%w\\n%h\\n\" " ^ " \"" ^ infile ^ "[" ^ (string_of_int (curr_page-1)) ^ "]\" ");
			in
			let w = input_line in_ch 
			and h = input_line in_ch  in
			ignore (Unix.close_process_in in_ch);
			(int_of_string h, int_of_string w);
			with _ -> (
				prerr_endline "Warning: could not determine page size; defaulting to A4.";
				(842,595) (*defaults to A4*))
		in
		let (height, width) = match page_width_height with
			| None -> (orig_height, orig_width)
			| Some x -> x
		in
		(*downscaling if resolution too large (requires gs):*)
		let convert_infile =
			let fw = float_of_int width
			and fh = float_of_int height
			and fm = float_of_int maxpixels in
			let pixels = (((float_of_int resolution) /. 72.) ** 2.) *. fw *. fh in
			
			let (new_height, new_width) =
				if pixels > fm then
				(
					let mpix = fm /. (((float_of_int resolution) /. 72.) ** 2.) in
					let k = fw /. fh in
					let new_width = int_of_float (sqrt (k *. mpix)) in
					let new_height = int_of_float ((sqrt mpix) /. (sqrt k)) in
					Printf.eprintf 
						"\n\nWARNING: page size (%ix%i) of page %i together with resolution %i yields very large file which exceeds parameter maxpixels. Most probably, the input file was accidentally generated in an inappropriately hight resolution.\nThe input file is scaled down to %ix%i pixels instead.\nIf such a large input file is really required, set the command line option -maxpixels greater than %.0f instead.\n\n" 
						width height curr_page resolution new_width new_height pixels;
					flush_all ();
					(new_height, new_width)
				)
				else (height, width)
				
			in
			
			if (new_height <> orig_height || new_width <> orig_width) then
			(
				run (
					Printf.sprintf 
						"%s  -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dFirstPage=%i -dLastPage=%i -dDEVICEWIDTHPOINTS=%i -dDEVICEHEIGHTPOINTS=%i -dPDFFitPage -o %s %s" 
						!gs curr_page curr_page new_width new_height tmprescaled_infile infile);
				tmprescaled_infile;
			)
			else
				(infile ^ "[" ^ (string_of_int (curr_page-1)) ^ "]")
		in
		let convoptstmp =
			if rgb then 
				" -depth 8 -background white -flatten -alpha Off -density " 
			else 
				if gray then " -colorspace gray -depth 8 -background white -flatten -alpha Off -density " else " -type Bilevel -density "
		in
		(*run (!convert ^ " -units PixelsPerInch " ^ convertopts ^ convoptstmp ^ (Printf.sprintf "%ix%i " resolution resolution)  ^ " \"" ^ convert_infile ^ "\" " ^  tmppicfile);*)
		run (!convert ^ " -units PixelsPerInch "  ^ convoptstmp ^ (Printf.sprintf "%ix%i " resolution resolution) ^ convertopts ^ " \"" ^ convert_infile ^ "\" " ^  tmppicfile);
		let tessout = if not !verbose then ">/dev/null 2>&1" else "" in
		let preproc_output = 
			if preprocess then
			(
				run (!unpaper ^ " --overwrite " ^ unpaperopts ^ " " ^ tmppicfile ^ " " ^ tmpunpaperfile ^ tessout);
				tmpunpaperfile
			)
			else tmppicfile
		in
		(*convert preprocessing output file to tif in order to ensure correct resolution and size:*)
		let tessinputfile = 
			run (!convert ^ " -units PixelsPerInch -density " ^ (Printf.sprintf "%ix%i" resolution resolution) ^ " " ^ preproc_output ^ " " ^ tmptessinpfile );
			tmptessinpfile
		in
		
		(*test if tesseract can output pdf files:*)
		run (!tesseract ^ " " ^ tessinputfile ^ tessout ^ " " ^ tmpocrfile ^ " " ^ tessopts ^ " -l " ^ language ^ " pdf ");
		
		if (not enforcehocr2pdf) && Sys.file_exists (tmpocrfile ^ ".pdf") then
		(
			if !verbose then pr ("OCR pdf generated. Renaming output file to " ^ pdfname ^ "\n");
			Unix.rename (tmpocrfile ^ ".pdf") pdfname;
		)
		else
		(
			if not !quiet then
				print_endline "Tesseract was unable to produce a pdf output file. Possibly, version of tesseract is prior to 3.03 and cannot output pdf yet. Using hocr2pdf instead.";
			run (!tesseract ^ " " ^ tessinputfile ^ tessout ^ " " ^ tmpocrfile ^ " " ^ tessopts ^ " -l " ^ language ^ " hocr ");
			let hocrinputfile = if Sys.file_exists (tmpocrfile ^ ".html") then tmpocrfile ^ ".html" else tmpocrfile ^ ".hocr" in
			run (!hocr2pdf ^ hocropts ^ " -r " ^ hocr_resolution ^ " -i " ^ tessinputfile ^ " -o " ^ pdfname ^ "<" ^ hocrinputfile);
			if not debug then Sys.remove hocrinputfile;
		);
		
		let rm_if_exists f = if Sys.file_exists f then Sys.remove f in
		if not debug then
		(
			rm_if_exists (tmpocrfile ^ ".pdf");
			rm_if_exists tmprescaled_infile;
			rm_if_exists tmptessinpfile;
			rm_if_exists tmppicfile;
			rm_if_exists tmpocrfile;
			rm_if_exists tmpcolfigfile;
			rm_if_exists tmpunpaperfile;
		);
	in
	let process_pagelist = Array.iter process_page in
	
	let tmppdf_arr = 
		Array.init pages_to_process (fun i -> (i+first_page, make_temp_file ".pdf"))
	in
	let intdiv = pages_to_process / nthreads
	and remainder = pages_to_process mod nthreads in
	
	let nested_arr =
		let rec f l ncum rmndr = function
			| 0 -> Array.of_list l
			| i -> 
				let npgs = intdiv + (if rmndr>0 then 1 else 0) in
				let ncum1 = ncum + npgs in
				let new_el = Array.sub tmppdf_arr ncum npgs in
				f (new_el::l) ncum1 (rmndr-1) (i-1)
		in
		f [] 0 remainder nthreads
	in

	let threadarr = Array.map (Thread.create process_pagelist) nested_arr in
	Array.iter Thread.join threadarr;
		
	let pdffilenamelist = List.map snd (Array.to_list tmppdf_arr) in
	let pdfliststring = String.concat " " pdffilenamelist in
	pr ("OCR done. Writing \"" ^ outfile ^ "\"");
	
	
	let tmpoutfile = 
		if List.length pdffilenamelist > 1 then
		(
			let tout = Filename.temp_file ~temp_dir:global_temp_dir "pdfsandwich_output" ".pdf" in
			run (!pdfunite ^ " " ^ pdfliststring ^ " " ^ tout);
			if (not debug) then List.iter Sys.remove pdffilenamelist;
			tout
		)
		else List.hd pdffilenamelist
	in
	
	try
	Unix.rename tmpoutfile outfile;
	with _ -> run("mv \"" ^ tmpoutfile ^ "\" \"" ^ outfile ^ "\"");
;;

let main () =
	let arg_filename = ref "" in
	let outputfile = ref "" in
	let first_page = ref 1
	and last_page = ref 0 in
	let resolution = ref 300 in
	let maxpixels = ref 17415167 in
	let lang = ref "eng" in
	let rgb = ref false in
	let gray = ref false in
	let preprocess = ref true in
	let unpaperopts = ref "" in
	let layout = ref "none" in
	let grayfilter = ref false in
	let hocropts = ref "" in
	let convertopts = ref "" in	(*additional convert options*)
	let tessopts = ref "" in	(*additional tesseract options*)
	let nthreads = ref 0 in
	let debug = ref false in
	let enforcehocr2pdf = ref false in
	let pagesize = ref "original" in
	let set_hocr_opts op () = hocropts := !hocropts ^ " " ^ op in
	let set_unp_opts op () = unpaperopts := !unpaperopts ^ " " ^ op in
	(* determins the number of threads tesseract may use for each page;
	if this is set to more than 1 it currently clashes with tesseract 4:*)
	let omp_thread_limit = ref 1 in
	
	let get_tesseract_language_list () = 
		let tesseract_langs =
			let in_ch = Unix.open_process_in (!tesseract ^ " --list-langs 2>&1") in
			let rec read_tess l =
				try
				let s = input_line in_ch in
				read_tess (s::l);
				with End_of_file -> 
					(ignore (Unix.close_process_in in_ch); l)
			in
			read_tess [];
		in
		if not (List.mem "eng" tesseract_langs) then
		(
			prerr_endline "Warning: tesseract option --list-langs not implemented. Cannot check languages. Make sure you have all necessary tesseract language packages installed.";
			[]
		)
		else 
		(
			match List.rev tesseract_langs with
			| [] -> []
			| h::t -> 
				if Str.string_match (Str.regexp "List of available languages") h 0 then t
				else h::t
		)
	in
		
	let speclist = [
		("-convert", Arg.Set_string convert, "\t -convert filename : name of convert binary (default: convert)");
		("-coo", Arg.Set_string convertopts, "\t\t -coo options : additional convert options; make sure to quote;\n\t\t  e.g. -coo \"-normalize -black-threshold 75%\"\n\t\t  call convert --help or man convert for all convert options");
		("-debug", Arg.Set debug, "\t keep all temporary files in /tmp (for debugging)");
		("-enforcehocr2pdf", Arg.Set enforcehocr2pdf, "\t use hocr2pdf even if tesseract >= 3.03");
		("-first_page", Arg.Set_int first_page, "\t -first_page number : number of page to start OCR from (default: 1)");
		("-grayfilter", Arg.Set grayfilter, "\t enable unpaper's gray filter; further options can be set by -unpo");
		("-gray", Arg.Set gray, "\t use grayscale for images (default: black and white);\n\t\t  will be overridden by use of rgb");
		("-gs", Arg.Set_string gs, "\t\t -gs filename : name of gs binary (default: gs); optional, only required for resizing");
		("-hocr2pdf", Arg.Set_string hocr2pdf, "\t -hocr2pdf filename : name of hocr2pdf binary (default: hocr2pdf);\n\t\t  ignored for tesseract >= 3.03 unless option -enforcehocr2pdf is set");
		("-hoo", Arg.String (fun s -> set_hocr_opts s()), "\t\t -hoo options : additional hocr2pdf options; make sure to quote");
		("-identify", Arg.Set_string identify, "\t -identify filename : name of identify binary (default: identify)");
		("-last_page", Arg.Set_int last_page, "\t -last_page number : number of page up to which to process OCR (default: number of pages in inputfile)");
		("-lang", Arg.Set_string lang, "\t -lang language : language of the text; option to tesseract (defaut: eng)\n\t\t  e.g: eng, deu, deu-frak, fra, rus, swe, spa, ita, ...\n\t\t  see option -list_langs;\n\t\t  Multiple languages may be specified, separated by plus characters.");
		("-layout", Arg.Set_string layout, "\t -layout { single | double | none } : layout of the scanned pages; requires unpaper\n\t\t  single: one page per sheet\n\t\t  double: two pages per sheet\n\t\t  none: no auto-layout (default)");
		("-list_langs", Arg.Unit (fun() -> List.iter print_endline (List.sort compare (get_tesseract_language_list ())); exit 0), "\t list currently available languages and exit;\n\t\t  in case of custom binaries of tesseract, place this after the -tesseract option");
		("-maxpixels", Arg.Set_int maxpixels, "\t -maxpixels NUM : maximal number of pixels allowed for input file\n\t\t  if (resolution/72)^2 *width*height > maxpixels then scale page of input file down\n\t\t  prior to OCR so that page size in pixels corresponds to maxpixels;\n\t\t  default: 17415167 (A3 @ 300 dpi)");
		("-noimage", Arg.Unit (set_hocr_opts "-n"), "\t do not place the image over the text (requires hocr2pdf; ignored without -enforcehocr2pdf option)");
		("-nopreproc", Arg.Clear preprocess, "\t do not preprocess with unpaper");
		("-nthreads", Arg.Set_int nthreads, "\t -nthreads number : number of parallel threads (default: guessed number of CPUs; if guessing fails: 1)");
		("-o", Arg.Set_string outputfile, "\t\t -o filename : output file; default: inputfile_ocr.pdf (if extension is different\n\t\t  from .pdf, original extension is kept)");
		("-omp_thread_limit", Arg.Set_int omp_thread_limit, "\t -omp_thread_limit number : number of threads tesseract may use for each page (default: 1)\n\t\tvalues greater than 1 may cause tesseract >=4 to hang up");
		("-pagesize", Arg.Set_string pagesize, "\t -pagesize { original | NUMxNUM } : set page size of output pdf (requires ghostscript)\n\t\t  original: same as input file (default)\n\t\t  NUMxNUM: width x height in pixel (e.g. for A4: -pagesize 595x842)");
		("-pdfinfo", Arg.Set_string pdfinfo, "\t -pdfinfo filename : name of pdfinfo binary (default: pdfinfo)");
		("-pdfunite", Arg.Set_string pdfunite, "\t -pdfunite filename : name of pdfunite binary (default: pdfunite)");
		("-resolution", Arg.Set_int resolution, "\t -resolution NUM : resolution (dpi) used for OCR (default: 300)");
		("-rgb", Arg.Set rgb, "\t\t use RGB color space for images (default: black and white);\n\t\t  use with care: causes problems with some color spaces");
		("-sloppy_text", Arg.Unit (set_hocr_opts "-s"), "\t sloppily place text, group words, do not draw single glyphs;\n\t\t  ignored for tesseract >= 3.03 unless option -enforcehocr2pdf is set");
		("-tesseract", Arg.Set_string tesseract, "\t -tesseract filename : name of tesseract binary (default: tesseract)");
		("-tesso", Arg.Set_string tessopts, "\t -tesso options : additional tesseract options; make sure to quote");
		("-unpaper", Arg.Set_string unpaper, "\t -unpaper filename : name of unpaper binary (default: unpaper)");
		("-unpo", Arg.String (fun s -> set_unp_opts s()), "\t -unpo options : additional unpaper options; make sure to quote");
		("-quiet", Arg.Set quiet, "\t suppress output");
		("-verbose", Arg.Set verbose, "\t produce more output");
		("-version", Arg.Unit (fun () -> Printf.printf "pdfsandwich version %s\n" pdfsandwich_version; exit 0), "\t print version and quit");
	] in
	
	Sys.remove global_temp_dir;
	Arg.parse speclist (fun s -> arg_filename := s) "USAGE: pdfsandwich [options] inputfile.pdf\n\nOptions:";
	Unix.mkdir global_temp_dir 0o700;
	
	List.iter check_for_binary [!convert; !tesseract; !gs; !pdfunite];
	if !enforcehocr2pdf then check_for_binary !hocr2pdf;
	if !preprocess then check_for_binary !unpaper;
	if !outputfile = "" then 
	(
		outputfile := Str.global_replace (Str.regexp "^\\(.+\\)\\.\\(....?\\)$") "\\1_ocr.\\2" !arg_filename;
		(*avoid input files to be overwritten:*)
		if !outputfile = !arg_filename then outputfile := !outputfile ^ "_ocr"
	);
	(try Unix.access !arg_filename [Unix.R_OK] with _ -> failwith ("Could not open file " ^ !arg_filename)); 
	pr ("pdfsandwich version " ^ pdfsandwich_version);
	if !verbose then	(*check versions of external programs:*)
	(
		let check_version progstring opt = 
			print_endline ("Checking for " ^ progstring ^ ":");
			run ~crash:false (progstring ^ " " ^ opt);
		in
		check_version !convert "-version";
		if !preprocess then check_version !unpaper "-V";
		check_version !tesseract "-v";
		if !enforcehocr2pdf then check_version !hocr2pdf "-h";
		check_version !gs "-v";
		check_version !pdfinfo "-v";
		check_version !pdfunite "-v";
	);
	
	if not !grayfilter then set_unp_opts "--no-grayfilter" ();
	set_unp_opts ("--layout " ^ !layout) ();
	
	let page_width_height =
		try
		match Str.split (Str.regexp_string "x") !pagesize with
		| width::height::[] -> Some (int_of_string width, int_of_string height)
		| _ -> None
		with _ -> failwith ("invalid pagesize value " ^ !pagesize)
	in
	
	(*check if requested language is supported by tesseract:*)
	let langlist = Str.split (Str.regexp_string "+") !lang in
	let tesseract_langs = get_tesseract_language_list () in
	
	if List.length tesseract_langs > 0 then
		List.iter 
			(fun s -> 
				if not (List.mem s tesseract_langs) then 
					failwith ("Language " ^ s ^ " not supported by tesseract. Make sure that the respective tesseract language package is installed.\n"))
			langlist;
	
	pr ("Input file: \"" ^ !arg_filename ^ "\"");
	pr ("Output file: \"" ^ !outputfile ^ "\"");
	(*use different filename for the input file in case the original input file contains special characters:*)
	let internal_input_filename = Filename.temp_file ~temp_dir:global_temp_dir "pdfsandwich_inputfile" ".pdf" in
	Sys.remove internal_input_filename;
	(*link original input file to internal_input_filename:*)
	let full_path_input_file = if Filename.is_relative !arg_filename then ((Sys.getcwd ()) ^ "/" ^ !arg_filename) else !arg_filename in
	Unix.symlink full_path_input_file internal_input_filename;
	
	let npages = number_of_pages internal_input_filename in
	pr ("Number of pages in inputfile: " ^ (string_of_int npages));
	if (!first_page < 1 || !first_page > npages) then failwith ("Value " ^ (string_of_int !first_page) ^ " is invalid as first_page.");
	if !last_page < 1 then last_page:= npages;
	if (!last_page < !first_page || !last_page > npages) then failwith ("Value " ^ (string_of_int !last_page) ^ " is invalid as last_page.");
	if !nthreads < 1 then (*guess number of CPUs*)
		nthreads := number_of_cpus ();
	let npages_to_process = !last_page - !first_page + 1 in
	if !nthreads > npages_to_process then
	(
		pr ("More threads than pages. Using " ^ (string_of_int npages_to_process) ^ " threads instead.");
		nthreads := npages_to_process;
	);
	(*precede tesseract call with a thread limit to prevent hang ups for tesseract >=4:*)
	tesseract := ("OMP_THREAD_LIMIT=" ^ (string_of_int !omp_thread_limit) ^ " " ^ !tesseract);
	
	process_ocr 
		internal_input_filename 
		!outputfile 
		!first_page !last_page 
		!resolution 
		!rgb 
		!gray
		!nthreads 
		!lang 
		!convertopts !tessopts !hocropts 
		!preprocess !unpaperopts 
		!debug 
		!enforcehocr2pdf 
		page_width_height
		!maxpixels;
	Unix.unlink internal_input_filename;
	pr ("\n" ^ !outputfile ^ " generated.\n\nDone.");
	if (not !debug) then Unix.rmdir global_temp_dir;
;;

main ();;

