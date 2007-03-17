module type S = sig
	type t
	type word
	type context
	val empty_freq_counter : unit ->  t
	val add_word :  t -> (context list) -> int -> word ->  t
end

module type Maps = sig
	module  WMap : Amap.S
	module  CMap : Amap.S
	val bos : CMap.key
end

(* nem sikerült olyan funktort létrehozni, aminek két modul a paramétere *)

(* A Contextek egymásba ágyazódhatnak, így egy fába tesszük őket. Például
	P(w3 | t2 t3) számolásához t3 -> t2 út van. Itt van egy map, ami a
	különböző szavak valószínűségét adja meg 
*)
module Make(M : Maps)  = struct

	
type word = M.WMap.key
type context = M.CMap.key
		
type  t = Parent of (float * t  M.CMap.t *  float M.WMap.t) |
			Terminal of (float * float M.WMap.t)


let empty_freq_counter () = Terminal(0.0, M.WMap.empty ())

let bos = M.bos
	
(* A B C trigram eseten A B a context es C a word. A B egy lista, ahol
   B az elso, A a masodik elem.
	
*)
let rec add_word context_node context n word  =
 (* mit kell csinalni? A context_tree-ben lefele menni, elfogyasztani
	a context listat. Minden szintent betenni word-ot.

 *)
	
	let words = match context_node with
		Terminal(_, words) -> words
		| Parent (_, _, words) -> words
	in
	(* elintezzuk a szot *)
	let _ = M.WMap.update words word (fun () -> 1.0) (fun x -> x +. 1.0) in
	
	(* es a funkcionalis fabejaras: lehet, h nem kell tovabbmenni.
	   De ez csak n-tol fugg. Ha a kontext elfogyott, akkor BOS cimkeket pakolunk be *)
	if n > 0 then
		let head, tail = match context with
			head :: tail -> head, tail
			| [] -> M.bos, []
		in
	
		let freq, childs = match context_node with
			Terminal(freq, _) -> freq, M.CMap.empty()
			| Parent(freq, childs,_) -> freq, childs
		in
		let _ = M.CMap.update childs head 
				(fun () -> add_word (empty_freq_counter ()) tail (pred n) word)
				(fun child -> add_word child tail (pred n) word)
		in
		Parent(freq +. 1.0, childs, words)
 	else
		match context_node with
				Parent(freq, childs, _) -> Parent(freq +. 1.0, childs, words)
				| Terminal(freq, _) -> Terminal(freq +. 1.0, words)
			
(* vegigmegy a context fan es ha level szintet lefele lepett, 
	akkor a gyokertol odaig tarto utat visszaadja *)
let iterate_paths f context_node level =
	let rec aux node acc level  =
		if level < 0 then ()
		else if level = 0 then
			f (node :: acc)
		else
			(* meg megyunk lefele *)
		match node with
			Terminal(_, _) -> ()
			| Parent(freq, childs, words) -> 
				let acc = node :: acc in
				M.CMap.iter (fun gram child -> aux child acc (pred level)) childs
	in
	aux context_node [] level

let get_words_from_node node =
	match node with
		Terminal(_, words) -> words
		| Parent(_, _, words) -> words




let total_context_freq node =
	match node with
		Terminal(freq, _) -> freq
		| Parent(freq, _, words) -> freq
;;

let word_count_at_context node =
	let words = get_words_from_node node
	in M.WMap.size words
	
let iter_words f node =
	let words = get_words_from_node node in
	M.WMap.iter f words
		
let calculate_lambdas context_node level =
	let lambdas = Array.create (level+2) 0.0 in
	
	
	(* ezt fogjuk a fa level szintu csomopontjain hivni; 
	   a context_nodes egy lista lesz, amiben legelol van a trigram *)
	let adjust_lambda context_nodes =
		let do_word word freq = 
			let rec search_max  nodes i max maxi =
				
				match nodes with 
					node::tail ->
						let context_freq, words = match node with
							Terminal(freq, words) -> freq, words
				   			| Parent(freq, _, words) -> freq, words
						in
						let word_freq = try M.WMap.find_save words word  
										with Not_found -> failwith "nem jo a fa";
						in
						
						let ratio = 
							(* hapaxokra Brants algoritmusa nem ter ki, kerdes
							   ilyenkor milyen lambdat szamoljunk? Mi felveszunk
							   egy lambda_0 erteket is, amit a search_max elso
							   hivasokor a maxi kepvisel, hiszen ilyenkor
							   nem lesz max-nal nagyobb tagja az osszeadasnak
							*)
							if context_freq = 1.0 || word_freq = 1.0 then -1.0 
						    else (context_freq -. 1.0) /. (word_freq -. 1.0)
						in
						let max, maxi = if ratio > max then (ratio, i) else (max, maxi) in
						search_max  tail (pred i) max maxi
					| _ -> (max,maxi)
			
			in
			let (max, maxi) = search_max context_nodes (level) (0.0) (level + 1) in 
			lambdas.(maxi) <-lambdas.(maxi) +. freq;
		in
		let words = get_words_from_node (List.hd context_nodes) in
		M.WMap.iter (do_word) words
	in
	iterate_paths adjust_lambda context_node level;
	let sum = Array.fold_left (fun sum x -> sum +. x) 0.0 lambdas in
	let lambdas = Array.map (fun x ->  x /. sum) lambdas in
	lambdas
	
(* fentrol lefele vegigmegyunk a fan, es minden csomopontban megnezzuk
	a szavakat, es a gyakorisagbol atterunk valoszinusegekre. Egy
	adott contextusban kell tudnunk az elozo szinten a szo gyakorisagat.
	
	A kontextusban kiszamoltuk C szo valoszinuseget, akkor mikor 
	lemegyunk A B kontextusban, hasznaljuk P (C | A) -t, hiszen
	P(C| A B) = l3 ML (C| A B) + l2 ML (C | B) + l1 ML (C) + l0, ami
	P(C| A B) = l3 ML (C| A B) + P (C | B) 
	
	*)
let counts_to_prob context_trie lambdas =
	(* ez megy lefele a faban *)
	let rec estimate_at_context node parent_words lambdas =
		match lambdas with
			[] -> (* ha nincs tobb lambda, akkor nincs mit szamolni
				     TODO: pruning. Ha ez nem terminal node, es van
				     a WMAP-ben, akkor torolni lehetne
				   *)
					()
			| l :: tl -> begin
				let context_freq, words = match node with
						Terminal(freq, words) -> freq, words
					  | Parent(freq, _, words) -> freq, words
				in
				(* minden szora kiszamoljuk a valoszinuseget *)
				let word_updater word freq =
					try
					let prob_to = M.WMap.find_save parent_words word in
					prob_to +. l *. (freq /. context_freq)	  
					with Not_found -> failwith ("rossz fa")
				in
				M.WMap.update_all words word_updater;
				(* fabejaras *)
				match node with
					Terminal(_,_) -> ()
					| Parent(_, childs, _) ->
					M.CMap.iter (fun gram child -> 
									estimate_at_context child words tl) childs
			end
	in
	(* legelol van a konstanst tag, aztan unigram... *)
	match  List.rev (Array.to_list lambdas) with
	[] -> failwith "List.length lambdas < 1"
	| l0 :: lambdas -> begin
	
	let null_context_freq, childs, words = match context_trie with
			Terminal(freq, words) -> failwith ("empty context_trie")
		  | Parent(freq, childs, words) -> freq, childs, words
	in
	(* elso szinten kicsit mashogy szamolunk *)
	M.WMap.update_all words (fun word freq -> l0 +. (freq /. null_context_freq));
	M.CMap.iter (fun gram child -> 
						estimate_at_context child words lambdas) childs
	end
	
(* egyszeruen le kell menni a legmelyebb kontextusba, ahol megvan *)
let wordprob trie word context =
	let rec aux node context prob_to =
		let words = get_words_from_node node in
		try
			let prob_here = M.WMap.find words word in
			(* lehet-e tovabbmenni? *)
			match (node, context) with 
				(Parent(_, childs, _), h::t) ->
				begin
			 		try
						let child_node = M.CMap.find childs h in
						aux child_node t prob_here;
					with Not_found -> prob_here
				end
			  | (_,_) -> (* nem lehet *) prob_here
		with Not_found -> prob_to
	in
	log (aux trie context neg_infinity)
	
end

