open Ast
open Ast_typing

type error_typ = { loc : localisation ; msg : string }
exception Typing_error of error_typ
 
let loc_dum = (Lexing.dummy_pos,Lexing.dummy_pos)

(* Dans la suite, ci veut dire classe ou interface, et bien souvent les paramstype
   sont aussi concernés, les vraies ci sont les classe et les interfaces.
   c veut dire classe, i interface, et parfois t paramtype *)

let type_fichier l_ci =
  (* ===== LES VARIABLES GLOBALES ===== *)
  (* J'utilise 3 lieux différents pour stocker des informations :
    1) Les variables globales : 
      Pour les informations uniquement sur les vraies ci
    2) Un env_typage_global :
      Qui contient toutes les informations communes, utiles et disponibles partout.
      Principalement initilisé au début, lors de la déclarations des vraies ci,
      mais pas que ! Lors de la déclarations, je récupère les méthodes, les champs
      et le constructeur. Le constructeur ne vaut que pour les vraies classes,
      on peut donc utiliser une variable globale. En revanche, on souhaite aussi
      connaitre les champs et les méthodes que possèdent les paramstypes, garantis 
      de par leurs contraintes. Ainsi pour grandement se simplifier, on stocke
      toutes les méthodes et les champs dans l'env_typage_global.
    3) Les env_typage spécifiques :
      Tout n'est pas commun, tout ce qui concernent les paramstype est gardé
      localement à une vraie ci. Pour reprendre le paragraphe précédent, les 
      méthodes et les champs des paramstype, sont propres à chaque env_typage 
      locaux. On accède aux environnements locaux via la table : env_locaux, 
      créée lors de l'étape de vérification des vraies ci. *)  

  let graph_c : (ident,node) Hashtbl.t = Hashtbl.create 5 in
  let graph_i : (ident,node) Hashtbl.t = Hashtbl.create 5 in 
  let ci_params : (ident,paramtype desc list) Hashtbl.t = Hashtbl.create 5 in
  let ci_params_tri : (ident,ident list) Hashtbl.t = Hashtbl.create 5 in
  let i_body : (ident,proto desc list) Hashtbl.t = Hashtbl.create 5 in 
  let c_body : (ident,decl desc list) Hashtbl.t = Hashtbl.create 5 in 
  let c_constr : (ident,info_constr) Hashtbl.t = Hashtbl.create 5 in
  let body_main : instr desc list ref = ref [] in
  
  let params_to_ids params = (* T1 , ... , Tn, juste les idents *)
    List.map (fun (p : paramtype desc) -> (p.desc).nom) params 
  in 
  
  (* = Initialisation de l'env_typage_global = *)
  let env_typage_global = {
    paramstype = IdSet.empty ; 
    ci = IdSet.empty ;
    c = IdSet.empty ; 
    i = IdSet.empty ;
    extends = Hashtbl.create 5 ;
    implements = Hashtbl.create 5 ;
    methodes = Hashtbl.create 5 ;
    champs = Hashtbl.create 5 ;
    tab_loc = Hashtbl.create 5} in

  let new_ci nom =
    env_typage_global.ci <- IdSet.add nom env_typage_global.ci in
  let new_c nom =
    new_ci nom ;
    env_typage_global.c <- IdSet.add nom env_typage_global.c in
  let new_i nom =
    new_ci nom ;
    env_typage_global.i <- IdSet.add nom env_typage_global.i in

  env_typage_global.c <- IdSet.of_list ["Main";"Object";"String"] ;
  env_typage_global.ci <- env_typage_global.c ;
  
  let tabmeth_String = Hashtbl.create 1 in
  Hashtbl.add tabmeth_String "equals"
    {nom="equals" ; id_ci = "String" ;
     typ=Some {loc = loc_dum ; desc = Jboolean} ; 
     types_params=[{loc = loc_dum ; desc = 
       Jntype {loc = loc_dum ; desc = Ntype ("String",[])}}]} ;
  Hashtbl.add env_typage_global.methodes "String" tabmeth_String ;
  Hashtbl.add env_typage_global.methodes "Object" (Hashtbl.create 0) ;
  let tabch_empty = Hashtbl.create 0 in
  Hashtbl.add env_typage_global.champs "String" tabch_empty ;
  Hashtbl.add env_typage_global.champs "Object" tabch_empty ;
  Hashtbl.add ci_params "Object" [];

  (* = Pour gérer les env_typage locaux = *)
  let env_locaux = Hashtbl.create 5 in

  let env_copy e =
    {paramstype = e.paramstype ;
    ci = e.ci ; c = e.c ; i = e.i ;
    extends = Hashtbl.copy e.extends ;
    implements = Hashtbl.copy e.implements ;
    methodes = Hashtbl.copy e.methodes ;
    champs = Hashtbl.copy e.champs ;
    tab_loc = Hashtbl.copy e.tab_loc }
  in
  (* Remarque : Oui j'ai préféré les Hashtbl aux Map, car plus pratiques :/ *) 



  (* ===== GRAPHES DES RELATIONS ENTRE LES C / LES I ===== *)
  (* On commence par récupérer toutes les relations, pour pouvoir traiter les I PUIS 
     les C dans un ordre topologique.
     ATTENTION, contrairement à ce qu'on pourrait penser, si on a :
     " class A <T extends B> " n'impose par une dépendance de A envers B.
     
     On en profite pour décortiquer l'arbre de syntaxe, et mettre des
     informations dans nos variables globales et notre env_typage_global. *)

  (* === Ajout des noeuds === *)
  let node_obj = {id="Object" ; mark = NotVisited ; prec=[] ; succ=[]} in
  Hashtbl.add graph_c "Object" node_obj ;

  let graph_add_node ci = match ci.desc with
    | Class {nom ; params ; body} ->
      Hashtbl.add ci_params nom params ;
      Hashtbl.add c_body nom body ;
      Hashtbl.add env_typage_global.tab_loc nom ci.loc ;

      if IdSet.mem nom env_typage_global.ci
        then raise (Typing_error {loc = ci.loc ; 
            msg = "Nom de classe ou interface déjà utilisé."})
      else (
        Hashtbl.add graph_c nom {id=nom ; mark = NotVisited ; prec=[] ; succ=[]} ;
        new_c nom )

    | Interface {nom ; params ; body} ->
      Hashtbl.add ci_params nom params ;
      Hashtbl.add i_body nom body ;
      Hashtbl.add env_typage_global.tab_loc nom ci.loc ;

      if IdSet.mem nom env_typage_global.ci
        then raise (Typing_error {loc = ci.loc ; 
            msg = "Nom de classe ou interface déjà utilisé."})
      else (
        Hashtbl.add graph_i nom {id=nom ; mark = NotVisited ; prec=[] ; succ=[]} ;
        new_i nom )

    | Main l -> 
      Hashtbl.add env_typage_global.tab_loc "Main" ci.loc ;
      body_main := l
      (* tjr traitée dernière *)
  in
  List.iter graph_add_node l_ci ;
 

  (* === Ajout des relations === *)
  (* Remarque : dans les graphes on ne regarde pas les relations C implements I, 
     car on va traiter les I avant. *)
  let dobj = {loc = loc_dum; desc = Ntype ("Object",[])} in
  let init_extends id l =
    Hashtbl.add env_typage_global.extends id l in
  let init_implements id l =
    Hashtbl.add env_typage_global.implements id l in
  
  init_extends "String" [dobj] ;
  init_implements "String" [] ;
  init_extends "Object" [] ;
  init_implements "Object" [] ;

  let graph_add_rel g node1 (dn : ntype desc) =
    let Ntype (id2,l_ntypes2) = dn.desc in
    let node2 = Hashtbl.find g id2 in
    node1.prec <- node2 :: node1.prec ; 
    node2.succ <- node1 :: node2.succ 
  in
  let verifie_c (dc : ntype desc) =
    let Ntype(id_c,_) = dc.desc in
    if not (IdSet.mem id_c env_typage_global.c)
    then raise (Typing_error {loc = dc.loc ;
      msg = "Classe inconnue."}) ;
    if id_c = "String" 
    then raise (Typing_error {loc = dc.loc ;
      msg = "Une classe n'a pas le droit d'hériter de String."}) ;
  in
  let verifie_i (di : ntype desc) =
    let Ntype(id_i,_) = di.desc in
    if not (IdSet.mem id_i env_typage_global.i)
    then raise (Typing_error {loc = di.loc ;
      msg = "Interface inconnue."})
  in


  let graph_add_vg ci = match ci.desc with
    | Class {nom ; extd=None ; implmts = l} ->
        List.iter verifie_i l ;
        init_extends nom [dobj] ;
        init_implements nom l ;
        let node_c = Hashtbl.find graph_c nom in
        node_c.prec <- [node_obj] ; 
        node_obj.succ <- node_c :: node_obj.succ
    | Class {nom ; extd=Some d_mere ; implmts = l} ->
        verifie_c d_mere ;
        List.iter verifie_i l ;
        init_extends nom [d_mere] ; 
        init_implements nom l ;
        let node_c = Hashtbl.find graph_c nom in
        node_obj.succ <- node_c :: node_obj.succ ;
        graph_add_rel graph_c node_c d_mere
    | Interface {nom ; extds = l} ->
        List.iter verifie_i l ;
        init_extends nom l ;
        init_implements nom [] ;
        let node_i = Hashtbl.find graph_i nom in
        List.iter (graph_add_rel graph_i node_i) l 
    | Main _ -> ()
  in
  List.iter graph_add_vg l_ci ;

  (* === Tri topologique === *)
  let rec parcours l n =
    if n.mark = NotVisited
    then (n.mark <- InProgress ;
      List.iter (parcours l) n.succ ;
      n.mark <- Visited ;
      l := n.id :: !l)
    else if n.mark = InProgress
    then raise (Typing_error {loc = Hashtbl.find env_typage_global.tab_loc n.id ;
          msg = "Il y a un cycle dans les héritages !"})
  in

  let list_cl = ref [] in (* ident list *)
  parcours list_cl node_obj ; (* Object est en tête *)
  
  let list_intf = ref [] in (* ident list *)
  Hashtbl.iter (fun i n -> parcours list_intf n) graph_i ;
  
  
  (* === Déclaration des paramstype === *)
  (* Justification de ce qu'on va faire et pourquoi maintenant :
     Très bientôt, pour faire quoique ce soit, on vérifiera que nos types sont bien fondés
     or pour faire ceci il faut que les types soient déjà déclarés, y compris les
     paramstype ! Vivant dans les différents env_typage locaux. On doit donc les déclarer
     dès maintenant, en revanche les paramstype pouvant faire référence à n'importe quelles
     vraies ci, il fallait bien déclarer les ci avant. 
     On doit non seulement renseigner leurs noms dans les env_typage locaux, 
     mais aussi leurs relations ! C'est le moment pour vérifier qu'il n'y a pas 
     de cycle dans la déclaration des paramstype.

     Attention, ici on ne peut pas vérifier que ces déclarations font sens, ie que
     les types sont bien fondés (du genre C<U extends B,T extends A<U>> 
     on ne peut pas vérifier que A<U> est bien bien fondé, puisque précisément on
     doit déclarer tous les paramstype avant. *)


  (* Que doit-on faire et comment :
     Pour une ci X<T1,...,Tn> il faut vérfier que les contraintes (/les extends)
     des Ti ne forment pas de cycle, puis on les traite dans un ordre topologique.
     On vérifie que les theta_i sont connus, et que ce sont des interfaces pour i>1.
     Si les conditions sont vérifiés, on rajoute les interfaces dans l'env_typage
     fraichement créé ! On rajoute les contraintes via env_typage.extends et implements, 
     mais aussi les méthodes nécessairement possédées par T, et évidemment on ajoute T 
     dans env_typage.paramstype.
     
     REMARQUE sur le comportement de java, on peut avoir Tk extends Tk' 
     MAIS dans ce cas Tk' doit être l'unique contrainte ! 

     Remarque sur mes choix, les paramstypes sont propres à une classe/interface,
     c'est une information qui nous sert localement pour vérifier les ci. Ainsi
     se trouve dans env_typage.paramstype uniquement les paramstype de la ci
     actuellement traitée. On génère un nouvel env_typage à chaque fois.
     Ainsi on ne risque pas de mélanger les paramstype entre ci. Si A et C utilisent
     des paramstype nommés "T", ils ne seront jamais mélangés. Les informations 
     utiles pour le traitement du corps des classes sont gardées dans chaque env_typage,
     qu'on peut récuperer via la table env_locaux. *)
     
  let declare_paramstype id_ci =
    let env_typage = env_copy env_typage_global in
    let dparams = Hashtbl.find ci_params id_ci in
    let params_id = params_to_ids dparams in (* T1 , ... , Tn, juste les idents *)
    env_typage.paramstype <- List.fold_left
      (fun set (dp : paramtype desc) -> 
        if IdSet.mem dp.desc.nom set 
        then raise (Typing_error {loc = dp.loc ;
          msg = "Nom de paramtype déjà utilisé ici."})
        else IdSet.add dp.desc.nom set) 
      IdSet.empty dparams ;
    
    let info_tmp = Hashtbl.create (List.length dparams) in
    (* (ident , info_paramtype_tmp) Hashtbl.t *)

    (* Déclaration des paramstype pour le tri topologique *)
    List.iter 
      (fun (p : paramtype desc) -> 
        Hashtbl.add env_typage.tab_loc (p.desc).nom p.loc ;
        Hashtbl.add info_tmp (p.desc).nom 
        {tk_mark = NotVisited ; tk_loc = p.loc ; 
         tk_contraintes = (p.desc).extds ;
         tk_fils = [] ; tk_pere = None })
      dparams ;
    
    (* Création des arêtes orientées entre les paramstype *)
    let recup_tk' tk = 
      let info_tk = Hashtbl.find info_tmp tk in
      match info_tk.tk_contraintes with 
      (* cf la remarque précédente sur le comportement de java *)
      | [({desc = Ntype (tk',[])} : ntype desc)] 
          when IdSet.mem tk' env_typage.paramstype
          -> let info_tk' = Hashtbl.find info_tmp tk' in
             info_tk'.tk_fils <- tk :: info_tk'.tk_fils ;
             info_tk.tk_pere <- Some tk'
      | _ -> ()
    in
    List.iter recup_tk' params_id ;

    (* Tri topologique *)
    let params_id_tri = ref [] in
    let rec parcours (tk : ident) =
      let info_tk = Hashtbl.find info_tmp tk in
      if info_tk.tk_mark = NotVisited 
      then begin 
        info_tk.tk_mark <- InProgress ; 
        List.iter parcours info_tk.tk_fils ;
        info_tk.tk_mark <- Visited ;
        params_id_tri := tk :: !params_id_tri end
      else if info_tk.tk_mark = InProgress
      then raise (Typing_error {loc = info_tk.tk_loc ;
            msg = "Il y a un cycle dans les paramstype"})
    in
    
    List.iter parcours params_id ;

    (* FINALEMENT peu importe dans quels sens on vérifie les paramstype,
       puisque soit cas 1 on a Tk extends Tk', auquel cas c'est ok.
       Soit cas 2 Tk ne dépend pas de d'autres paramstype.
       D'ailleurs dans le cas 2 quand on fait les vérications, si on tombe sur
       un Tk' il faut planter.

       ATTENTION, on peut appeler un paramtype par le nom d'une ci, 
       même interface I<I> est autorisé. Dans ce cas on écrase la ci, 
       ma méthode consisterai à supprimer les ci portant le nom de paramtype. 
       FINALEMENT je ne vais pas le faire, parce que je manque du temps et
       c'est compliqué, car si on a I<A extends C> et d'autre part une classe A
       et une classe C extends A, il faut garder l'ancien. Mais du coup il y
       a un gros mélange, on peut imaginer des cas tordus. Je chercherai 
       peut-être un jour une meilleure façon de faire. 
       
       ATTENTION, retournement de situation ! 
       Ici, dans la vérification des paramstype, on peut effectivement traiter les
       paramtype dans un ordre quelconque. EN REVANCHE, pour les classes, 
       on va récupérer les méthodes et les champs des paramtypes, et là on doit
       absoluement les traiter dans un ordre topologique. 
       Exemple : avec <X entends Y, Y extends A & I>
       On doit commencer par Y, qui possède les champs de A, les méthodes de A et
       les méthodes demandées par I. Ensuite on héritera tout pour X. 
       -> C'est là toute l'importance de ci_params_tri 
       rem : On ne peut pas réarranger ci_params, sinon les substitutions vont 
       mal se passer !    *)
    
    (* = Sauvegarde d'un ordre topologique = *)
    Hashtbl.add ci_params_tri id_ci !params_id_tri ;

    (* = *)
    let declare_relations_paramtype (tk : ident) = 
      env_typage.ci <- IdSet.add tk env_typage.ci ;
      env_typage.c <- IdSet.add tk env_typage.c ;
      let {tk_contraintes ; tk_pere} = Hashtbl.find info_tmp tk in
      match tk_pere with (* Pour faire les relations extends/implements *)
        | Some tk' ->
            let info_tk' = Hashtbl.find info_tmp tk' in
            Hashtbl.add env_typage.extends tk 
              [{loc = info_tk'.tk_loc ; desc = Ntype (tk',[])}] ;
            Hashtbl.add env_typage.implements tk []
        | None -> begin
            match tk_contraintes with 
            | [] ->  
                Hashtbl.add env_typage.extends tk [dobj] ; 
                Hashtbl.add env_typage.implements tk []
            | (dci : ntype desc) :: q ->
                (* Je ne peux pas encore vérifier que les types évoqués sont bien typés,
                   Je suis obligé de faire confiance !  *)
                (* De même on supp que les contraintes suivantes sont effectivements des i *)
                let Ntype (id_ci,_) = dci.desc in
                if IdSet.mem id_ci env_typage.paramstype 
                then raise (Typing_error {loc = dci.loc ;
                  msg = "Si un paramtype (ici : " ^ tk ^ ") dépend d'un autre (ici : "
                      ^ id_ci ^ " ce doit être l'unique contrainte pour " ^ tk ^ "."}) ;
                if id_ci = "String" 
                then raise (Typing_error {loc = dci.loc ;
                  msg = "Rien doit hériter de String"}) ;
                if IdSet.mem id_ci env_typage.c
                then (Hashtbl.add env_typage.extends tk [dci] ;
                      Hashtbl.add env_typage.implements tk q)
                else (
                  Hashtbl.add env_typage.extends tk [dobj] ;
                  Hashtbl.add env_typage.implements tk tk_contraintes) ;
        end
    in
    List.iter declare_relations_paramtype params_id ;
    (* params_id juste pour montrer qu'on n'a pas besoin d'utiliser params_id_tri ici *)

    Hashtbl.add env_locaux id_ci env_typage 
  in

  List.iter declare_paramstype (List.tl !list_cl) ; (* On saute Object *)
  List.iter declare_paramstype !list_intf ; 
  (* ======================= *)



  
  (* ===== Sous-type / Extends / Implements Généralisées / Bien fondé ===== *)
  (* ATTENTION, là on utilise les relations, on ne les vérifie pas *)
  (* Les fonctions sont des tests, par exemple verifie_bf vérifie si un type est bien
     fondé, le type de retour est unit, mais on peut raise l'erreur lors de la vérification,
     cela permet de localiser les problèmes précisément, mais le mieux serait souvent
     de rattraper l'erreur, pour préciser le contexte (pourquoi on voulait sous-type 
     par exemple). *)

  (* === Pour les substitutions des paramstype avec sigma === *)
  let fait_sigma id_ci loc l_ntypes =
    (* ATTENTION, je n'ai pas suffisament fait attention, et je l'ai réalisé seulement
       grâce aux tests. Pour hériter des méthodes ou des champs par exemple, on a besoin
       de traduire les types de retours, ie les substituer, on fabrique donc sigma.
       Sauf qu'un paramtype peut hériter d'un autre, et donc fabriquer sigma est impossible
       car on ne trouvera pas les paramstype du paramtype père !
       Ma solution consiste à vérifier si id_ci a une liste de paramstype associée,
       si ce n'est pas le cas, c'est que nous avons là un paramtype, et donc il n'a pas
       de paramstype, donc sigma est trivial. *)
    let sigma = Hashtbl.create (List.length l_ntypes) in
    begin match Hashtbl.find_opt ci_params id_ci with
    | None -> sigma (* id_ci est un paramtype *)
    | Some dparams ->
      let params_id = params_to_ids dparams in
      try List.iter2 
            (fun id (dn : ntype desc) -> 
              Hashtbl.add sigma id dn.desc) 
            params_id l_ntypes ;
          sigma
      with | Invalid_argument _ -> 
        raise (Typing_error {loc = loc ;
          msg = "Trop ou pas assez de paramstype" })
    end
  in

  let rec substi_list sigma l_ntypes =
    List.map (fun (dn : ntype desc) -> 
      {loc=dn.loc  ; desc=substi sigma dn.desc}) l_ntypes
  and substi sigma (Ntype (id,l)) =
    if Hashtbl.mem sigma id
      then (Hashtbl.find sigma id)
    else Ntype(id, substi_list sigma l)
    (* Soit id est un paramtype, on le change (d'ailleurs l=[]).
       Soit id est un type construit, qui a potentiellement des paramstypes. *)
  in
  let substi_jt sigma jt = match jt with
    | Jboolean | Jint -> jt
    | Jtypenull -> failwith "Normalement, le parser fait que ça n'arrive pas"
    | Jntype dnt -> Jntype ({loc = dnt.loc ; desc = substi sigma dnt.desc})
  in
  let substi_dj sigma (dj : jtype desc) =
    {loc = dj.loc ; desc = substi_jt sigma dj.desc}
  in
  let substi_djo sigma (djo : jtype desc option) = match djo with
    | None -> None
    | Some dj -> Some (substi_dj sigma dj) 
  in
  let substi_list_dj sigma (l_dj : jtype desc list) =
    List.map (substi_dj sigma) l_dj 
  in
  (* ======================= *)
 
  (* === Extends généralisée === *) 
  (* Pratiquement toujours contenu dans le test de sous_type.
     SAUF dans le cadre d'héritage de méthode, voir plus loin. *)
  let rec extends (dci1 : ntype desc) (dci2 : ntype desc) env_typage =
    (* Attention, on passe par un env, car on peut avoir id1 = T paramtype *)
    (Ntype.equal dci1.desc dci2.desc)
    || 
    begin
    let Ntype (id1,l_ntypes1) = dci1.desc in
    let Ntype (id2,l_ntypes2) = dci2.desc in
    if not (IdSet.mem id1 env_typage.ci)
      then raise (Typing_error {loc = dci1.loc ;
        msg = "Classe ou interface inconnue dans le contexte"}) ;
    if not (IdSet.mem id2 env_typage.ci)
      then raise (Typing_error {loc = dci2.loc ;
        msg = "Classe ou interface inconnue dans le contexte"}) ;

    let l_precs1 = Hashtbl.find env_typage.extends id1 in
    let sigma = fait_sigma id1 dci1.loc l_ntypes1 in
    List.exists
      (fun dci -> extends dci dci2 env_typage)  
      (substi_list sigma l_precs1)
    end
  in
  let verifie_extends dci1 dci2 env_typage = 
    if not (extends dci1 dci2 env_typage)
    then (let Ntype (id1,_) = dci1.desc in
      let Ntype (id2,_) = dci2.desc in
      raise (Typing_error {loc = dci1.loc ;
      msg = (Ntype.to_str dci1) ^ " n'est pas connu comme étendant " 
          ^ (Ntype.to_str dci2) }))
  in
  let extends_jtype_opt (djo1 : jtype desc option) (djo2 : jtype desc option) env_typage = 
    match djo1 , djo2 with
    | None,None -> true (* void et void *)
    | Some dj1,Some dj2 ->
      begin match dj1.desc , dj2.desc with
        | Jboolean , Jboolean | Jint , Jint -> true
        | Jntype dnt1 , Jntype dnt2 -> extends dnt1 dnt2 env_typage 
        | _ , _ -> false
      end
    | _,_ -> false
  in
  (* ======================= *)

  (* === Implements généralisée === *)
  let rec implements dc di env_typage = 
    let Ntype (id_c,l_ntypes_c) = dc.desc in
    let Ntype (id_i,l_ntypes_i) = di.desc in
    if not (IdSet.mem id_c env_typage.c)
      then raise (Typing_error {loc = dc.loc ;
        msg = "Classe inconnue dans le contexte"}) ;
    if not (IdSet.mem id_i env_typage.i)
      then raise (Typing_error {loc = di.loc ;
        msg = "Interface inconnue dans le contexte"}) ;

    let sigma = fait_sigma id_c dc.loc l_ntypes_c in
    ( let l_implements = Hashtbl.find env_typage.implements id_c in 
      List.exists 
      (fun (di' : ntype desc) -> 
        extends di' di env_typage)
      (substi_list sigma l_implements) )
    ||
    ( let l_extends = Hashtbl.find env_typage.extends id_c in
      (* Même si en soit il y a au plus une sur-classe *)
      List.exists
      (fun dc' -> implements dc' di env_typage)
      (substi_list sigma l_extends) )
  in
  let verifie_implements dc di env_typage = 
    if not (implements dc di env_typage)
    then (let Ntype (id_c,_) = dc.desc in
      let Ntype (id_i,_) = di.desc in
      raise (Typing_error {loc = dc.loc ;
      msg = (Ntype.to_str dc) ^ " n'est pas connue comme implémentant " 
          ^ (Ntype.to_str di) }))
  in
  (* ======================= *)

  (* === Sous-Type === *)
  let rec sous_type jtyp1 jtyp2 env_typage = match jtyp1,jtyp2 with
    | Jtypenull,_ 
    | Jboolean,Jboolean | Jint,Jint -> true
    | Jntype {desc = d1},Jntype {desc = d2} when Ntype.equal d1 d2 -> true
    | Jntype dci, _ ->
        let Ntype (id_ci,l_ntypes_ci) = dci.desc in
        if not (IdSet.mem id_ci env_typage.ci)
          then raise (Typing_error {loc = dci.loc ;
            msg = "Classe ou interface inconnue dans le contexte"}) ;
        
        let sigma = fait_sigma id_ci dci.loc l_ntypes_ci in
        let l_precs = Hashtbl.find env_typage.extends id_ci in
        
        (List.exists (* Règle 4 des sous-types *)
          (fun dci' -> sous_type (Jntype dci') jtyp2 env_typage)
          (substi_list sigma l_precs)  )
        || (* La règle 5 *)
        (* ATTENTION, il me semble qu'elle est fausse (version 3 du sujet), 
           cf mon rapport. *)
        (match jtyp2 with | Jntype di -> implements dci di env_typage | _ -> false )
    | _,_ -> false
  in
  let verifie_sous_type jtyp1 loc1 jtyp2 env_typage = 
    if not (sous_type jtyp1 jtyp2 env_typage)
    then (raise (Typing_error {loc = loc1 ;
      msg = (str_of_jtp jtyp1) ^ " n'est pas un sous-type de " ^ (str_of_jtp jtyp2) }))
      (* On pourrait rajouter la loc2... *)
  in
  let verifie_sous_type_opt (djo1 : jtype desc option) loc1 
    (djo2 : jtype desc option) env_typage = match djo1 , djo2 with
      | None , None -> () (* void et void *)
      | Some dj1 , Some dj2 ->
          verifie_sous_type dj1.desc dj1.loc dj2.desc env_typage
      | _ , _ -> raise (Typing_error {loc = loc1 ;
      msg = (str_of_djo djo1) ^ " n'est pas un sous-type de " ^ (str_of_djo djo2) })
  in
  (* ======================= *)

  (* === Bien Fondé === *)
  let rec verifie_bf jtyp env_typage = match jtyp with
    | Jboolean | Jint | Jtypenull -> () (* une fonction vérifie est à valeur dans unit *)
    | Jntype {loc ; desc = Ntype (id_ci,l_ntypes)} ->
        if not (IdSet.mem id_ci env_typage.ci)
          then raise (Typing_error {loc=loc ;
            msg = "Classe ou interface inconnue"}) ;
        if l_ntypes = [] then ()
        else begin
        (* id a des paramtypes, en particulier id n'est pas un paramtype *)
        let dparams = Hashtbl.find ci_params id_ci in
        let params_id = params_to_ids dparams in (* T1 , ... , Tn, juste les idents *)
        (* d_mere vit dans env_typage_id_ci, exemple : A<T extends B & I,U extends T>
           on cherche à vérifier que A<X,Y> est bien fondé, où X et Y vivent dans 
           l'env_typage actuel ! On doit vérifier que X extends B et implements I, 
           ce qui est dit dans env_typage !, puis que Y extends X ! On substitue 
           les informations de l'env_typage_id_ci avec ce qu'on sait actuellement ! *)
        let env_typage_id_ci = Hashtbl.find env_locaux id_ci in
        let sigma = fait_sigma id_ci loc l_ntypes in
        try
          List.iter2
            (fun id_p dn ->
              verifie_bf (Jntype dn) env_typage ;
              let d_mere = List.hd (Hashtbl.find env_typage_id_ci.extends id_p) in
              let d_mere = {loc = d_mere.loc ; desc = substi sigma d_mere.desc} in
              let l_implements = Hashtbl.find env_typage_id_ci.implements id_p in
              let l_implements = substi_list sigma l_implements in
              verifie_extends dn d_mere env_typage ; (* verifie_sous_type fait l'affaire ? *)
              List.iter (fun di' -> verifie_implements dn di' env_typage) l_implements ;
            )
            params_id l_ntypes
        with
          | Invalid_argument _-> raise (Typing_error {loc=loc ;
              msg = "Trop ou pas assez de paramstype"})
        end
  in
  (* ======================= *)



  (* ===== DECLARATIONS ET VERIFICATION DES HÉRITAGES ===== *)
 
  (* === Vérification des paramstype === *)
  (* Pour rappel, les paramstype ont déjà été déclarer en amont des fonctions
     verifie_bf/extds/implmts etc. Il nous reste juste à vérifier que les
     types mentionnés sont bien fondés. *)   
  let verifie_paramstype id_ci env_typage =
    let dparams = Hashtbl.find ci_params id_ci in
    List.iter
      (fun (p : paramtype desc) ->
        match p.desc.extds with
        | [] -> ()
        | (dci : ntype desc) :: q ->
          verifie_bf (Jntype dci) env_typage ;
          List.iter (* On vérifie que les contraintes suivantes st des interfaces *)
            (fun (dn : ntype desc) -> 
              verifie_bf (Jntype dn) env_typage ;
              let Ntype (id',l_ntypes') = dn.desc in
              if not (IdSet.mem id' env_typage.i)
              then raise (Typing_error {loc = dn.loc ;
                msg = "On attend des interfaces en contraintes supplémentaires"})
            ) q 
      ) dparams 
  in
  (* ======================= *)


  (* === LES METHODES : Héritage et vérification redéfinition === *)

  (* Je dis que deux méthodes sont en relations, si l'une appartient à une sur-ci
     de l'autre, ou si une ci hérite des deux. 
     Les paramètres doivent alors être de même types.*)
  let verifie_meme_parametres (meth : info_methode) (meth' : info_methode) loc=
    try List.iter2
      (fun (d_jtype : jtype desc) (d_jtype' : jtype desc) ->
        if not (jtype_equal d_jtype.desc d_jtype'.desc)
        then raise (Typing_error {loc = d_jtype.loc ;
          msg = "Problème avec les méthodes nommées" ^ meth.nom
             ^ ", deux méthodes en relation doivent avoir des paramètres de même types."}))
      meth.types_params meth'.types_params
    with | Invalid_argument _ -> 
        raise (Typing_error {loc = loc ;
          msg = "Problème avec les méthodes nommées" ^ meth.nom
             ^ ", deux méthodes en relation doivent avoir autant de paramètres."})
  in

  let recup_methodes (dci' : ntype desc) env_typage =
    (* ATTENTION : 
       Grâce aux tests j'ai réalisé une grosse erreur :
       Au début, j'insère les méthodes et champs des vrais ci dans env_typage_global.
       Donc pour récupérer les méthodes, c'est là-bas qu'il faut chercher.
       MAIS pour fabriquer les méthodes et champs des paramstype, puisqu'on
       peut faire référence à d'autres paramstype, tout doit se passer dans 
       l'env_typage local ! *)
    let Ntype (id_ci',l_ntypes_ci') = dci'.desc in
    (* Il faut substituer les paramstype dans les types de retour des méthodes héritées *)
    (* MAIS aussi dans les paramètres, voir l'exemple correcte test9.java.
       << interface I<U> { U m();}
          interface J<U> { U m();}
          interface K extends I<String>,J<String> {String m();} >> *)
    let sigma = fait_sigma id_ci' dci'.loc l_ntypes_ci' in
    let sur_methodes : methtab = Hashtbl.create 0 in
    Hashtbl.iter
      (fun nom (meth : info_methode) -> 
        Hashtbl.add sur_methodes nom 
         {nom = meth.nom ; id_ci = meth.id_ci ; 
          typ = substi_djo sigma meth.typ ; 
          types_params = substi_list_dj sigma meth.types_params } )
      (Hashtbl.find env_typage.methodes id_ci') ;
    sur_methodes
  in
  
  (* BUT : Renvoyer une methtab contenant toutes les méthodes héritées.
       
       ATTENTION : si une méthode est présente dans deux ci mères (comme ce
       peut être le cas avec des interfaces), alors :
       il faut les mêmes arguments et il faut une relation entre les types de
       retour, typiquement si dans une des classes/interfaces mères on a T1 m() et dans
       une autre T2 m(), alors il faut T1 extends(généralisée) T2 ou T2 extends T1
       (en particulier T1 et T2 doivent être deux classes ou deux interfaces).
       Je dis bien, extends et non sous-type !! Auquel cas le type de retour hérité 
       sera le plus petit des différents types de retours.
       Ensuite si on redéfinit il faudra un sous-type de ce type hérité. 

       Remarque : on n'a pas besoin de remonter l'arbre des extensions,
       les ci_meres contiennent déjà celles des ancêtres. 

       Remarque : Dans le info_methode, on retient aussi le nom de la ci 
       d'où provient cette méthode, pratique pour envoyer des messages d'erreurs précis.*)

  let heritage_d'une_surci id_ci loc_ci methodes_heritees env_typage global 
    (dci' : ntype desc) =
    (* global : bool: selon où on cherche les méthodes
       cf mon attention dans recup_methodes *) 
    let Ntype (id_ci',l_ntypes_ci') = dci'.desc in
    let sur_methodes = 
      recup_methodes dci' (if global then env_typage_global else env_typage) in
    let traite_methode nom (meth' : info_methode) =
      match (Hashtbl.find_opt methodes_heritees nom) with
        | None -> Hashtbl.add methodes_heritees nom meth'
        | Some meth'' -> 
            verifie_meme_parametres meth' meth'' loc_ci;
            if not (extends_jtype_opt meth''.typ meth'.typ env_typage)
            then if (extends_jtype_opt meth'.typ meth''.typ env_typage)
            then Hashtbl.replace methodes_heritees nom meth'
            else raise (Typing_error {loc = loc_ci ;
              msg = id_ci ^ " hérite de la méthode " ^ nom ^ " via "
                  ^ id_ci' ^ " avec le type de retour " ^ (str_of_djo meth'.typ)
                  ^ " mais aussi via " ^ meth''.id_ci ^ " avec le type de retour "
                  ^ (str_of_djo meth''.typ) 
                  ^ " or ces types ne sont pas en relations, l'un doit extends l'autre."})
            (* Au lieu de fournir juste loc_ci, ça serait cool de remonter l'arbre
               de extends en montrant d'où viennent les méthodes en conflits *)
            (* else on n'a pas à changer *)
            (* ATTENTION, je ne garantie rien dans les tests d'extends, 
               l'env de typage peut être très bizarre, dans le cas où des
               paramstype reprennent le nom de vraies ci. 
               Cf ma remarque à ce propos dans verifie_et_fait_paramstype. *) 
    in
    Hashtbl.iter traite_methode sur_methodes
  in
  let herite_methodes id_ci loc_ci env_typage =
    let methodes_heritees : methtab = Hashtbl.create 5 in 
    let extends = Hashtbl.find env_typage.extends id_ci in
    List.iter (heritage_d'une_surci id_ci loc_ci methodes_heritees env_typage true) extends ;
    methodes_heritees 
  in

  let verifie_parametres env_typage params = 
    let param_set = ref IdSet.empty in
    List.iter 
      (fun (dp : param desc) -> 
        if IdSet.mem dp.desc.nom !param_set
        then raise (Typing_error {loc = dp.loc ;
          msg = "Deux paramètres ne doivent pas avoir le même nom."})
        else param_set := IdSet.add dp.desc.nom !param_set ;
        verifie_bf dp.desc.typ.desc env_typage)
      params
  in
  let verifie_et_fait_methode (type_retour : jtype desc option) nom params id_ci 
          loc env_typage methodes =
    (* vérifie type de retour *)
    begin match type_retour with
      | None -> ()
      | Some tr -> verifie_bf tr.desc env_typage
    end ;
    (* vérifie type des paramètres *)
    verifie_parametres env_typage params ;
    (* vérifie rédéfinition propre *)
    let types_params = 
      List.map (fun (dp : param desc) -> (dp.desc).typ) params in
    let meth = {nom = nom ; id_ci = id_ci ; 
      typ = type_retour ; types_params = types_params} in
    begin match (Hashtbl.find_opt methodes nom) with
      | None -> () 
      | Some meth' ->
          verifie_meme_parametres meth meth' loc;
          verifie_sous_type_opt meth.typ loc meth'.typ env_typage end ;
     Hashtbl.replace methodes nom meth
     (* Pour les avoir toutes au même endroit...  
        d'ailleurs c'est forcément la nouvelle def qui l'emporte et là
        la contrainte est plus souple, avec un sous_type et non extends *)
     (* Là clairement on peut bien mieux faire en terme de message d'erreur :/ *)
  in
  (* ======================= *)


  (* === Construction des infos sur les paramstypes, pour les classes === *)
  let recup_champs_methodes_paramstype id_c env_typage =
    (* ici on a déjà verifié et ajouté les paramstype *)
    let params_id_tri = Hashtbl.find ci_params_tri id_c in
    (* C'est précisément maintenant qu'on a besoin d'un ordre topologique,
       cf mon Attention dans verifie_et_fait_paramstype *) 
    let fait_un_paramtype id_t =
      let loc_t = Hashtbl.find env_typage.tab_loc id_t in
      (* = Les méthodes = *)
      let methodes_heritees : methtab = Hashtbl.create 5 in 
      let dc_mere = List.hd (Hashtbl.find env_typage.extends id_t) in
      heritage_d'une_surci id_t loc_t methodes_heritees env_typage false dc_mere;
      let implements = Hashtbl.find env_typage.implements id_t in
      List.iter 
        (heritage_d'une_surci id_t loc_t methodes_heritees env_typage false) 
        implements ;
      Hashtbl.add env_typage.methodes id_t methodes_heritees ; 
      (* ATTENTION, je n'ai pas vérifié le comportement de java quand on
         hérite d'une méthode m() renvoyant un T1 et qu'on implémente une interface
         qui demande m() renvoyant un T2. Actuellement je prends le plus petit des deux.
         Peut-être qu'il faudrait toujours garder T1. *)

      (* = Les champs = *)
      let Ntype(id_m,l_ntypes_m) = dc_mere.desc in
      let sigma = fait_sigma id_m dc_mere.loc l_ntypes_m in
      let champs : chtab = Hashtbl.create 5 in
      Hashtbl.iter
        (fun nom (champ : info_champ) ->
          Hashtbl.add champs nom
            {nom = champ.nom ; id_c = champ.id_c ; 
            typ = substi_dj sigma champ.typ } )
        (Hashtbl.find env_typage.champs id_m) ; 
      Hashtbl.add env_typage.champs id_t champs
    in
    List.iter fait_un_paramtype params_id_tri
  in
  (* ======================= *)


  (* === LES INTERFACES  === *)
  (* Contrairement aux classes, elles ne servent qu'à vérifier le typage
     dans la production de code, on n'en a plus besoin.
     Donc on se contente de vérifier le typage, on ne renvoie rien.
     ET on les vérifie dans un ordre topologique. *)
  let verifie_bf_et_i env_typage (di' : ntype desc) =
      verifie_bf (Jntype di') env_typage ;
      let Ntype (id_i',l_ntypes_i') = di'.desc in
      if not (IdSet.mem id_i' env_typage.i)
      then raise (Typing_error {loc = di'.loc ;
        msg = "On attendait une interface et non une classe/paramtype"})
  in
  let verifie_interface id_i =
    let env_typage = Hashtbl.find env_locaux id_i in

    (* Première étape : les paramstype *)
    verifie_paramstype id_i env_typage ;

    (* Deuxième étape : les extends *)
    let extends = Hashtbl.find env_typage.extends id_i in
    List.iter (verifie_bf_et_i env_typage) extends ;
    
    (* Troisième étape : les méthodes *)
    (* Les méthodes demandées par i comprennent toutes les méthodes demandées
       par une sur-interface de i. 
       Si on redéfinit une méthode, on doit vérifier que les paramètres sont 
       de même type, et que le type de retour est un sous-type. 
       Cf les très nombreuses remarques à ce propos dans les fonctions dédiées. *)

    let (body : proto desc list) = Hashtbl.find i_body id_i in
    let loc_i = Hashtbl.find env_typage.tab_loc id_i in
    let methodes = herite_methodes id_i loc_i env_typage in 
    let ajoute_meth (d_proto : proto desc) =
      let pro = d_proto.desc in
      verifie_et_fait_methode pro.typ pro.nom pro.params id_i 
        d_proto.loc env_typage methodes 
    in
    List.iter ajoute_meth body ;
    Hashtbl.add env_typage_global.methodes id_i methodes
    (* Attention : les méthodes de l'interface partent dans l'env global !!
       Et c'est tout ce qu'on garde, on ne sauvegarde pas l'env local,
       pour les interfaces on s'arrête là. 
       On pourrait bidouiller pour rajouter les méthodes et les champs des vraies
       ci directement dans tous les env_locaux. En initialisant au tout début 
       des Hashtbl vides pour chaque vraies ci dans l'env_typage_global, puis en
       rajoutant les méthodes et les champs à ces tables. Qui serait commune à 
       tout les env_typage, malgré le env_copy. 
       Mais c'est inutilement compliqué. *)
  in
  
  List.iter verifie_interface !list_intf ;
  (* ======================= *)


  (* === LES CLASSES === *)
  (* La vérification des classes se fait en 2 temps. 
     1) Déclaration - pour *toutes* les classes : 
       -On déclare les paramstype 
       -On controle l'existence de la surclasse
       -On déclare les méthodes, les champs et le constructeur, en vérifiant
        les types des paramètres et le type de retour, et surtout on gère
        l'héritage des méthodes.
       -On controle les implements, en vérifiant chaque méthode !
     2) PUIS à nouveau pour *toutes* les classes :
       -On récupère les champs et les méthodes des paramstype,
        en suivant un ordre topologique au sein des paramstype.
     
     On est obligé de commencer par déclarer toutes les méthodes et les champs, 
     et ce dans toutes les classes (plus exactement dans toutes les vraies ci,
     sachant que les interfaces ont déjà été faites), avant de passer aux paramstypes. 
     Car on peut avoir A<I extends B> et B<I extends A>. 
     Utiliser un ordre topologique sur les classes est crucial dans la première partie,
     exactement pour comme pour les interfaces précédemment. *)

  let verifie_classe id_c =
    let env_typage = Hashtbl.find env_locaux id_c in
    let loc_c = Hashtbl.find env_typage.tab_loc id_c in
    (* Déclaration des paramstype *)
    verifie_paramstype id_c env_typage ;  

    (* La sur-classe *)
    let d_mere = List.hd (Hashtbl.find env_typage.extends id_c) in
    (* Une classe hérite toujours d'une seule autre classe, possiblement d'Object,
       exceptée pour Object, mais qu'on n'a pas besoin de traiter. *)
    let Ntype(id_m,l_ntypes_m) = d_mere.desc in
    if id_m = "String"
    then raise (Typing_error {loc=d_mere.loc ;
      msg = "On ne doit pas hériter de la classe String" }) ;
    if not (IdSet.mem id_m env_typage.c)
    then raise (Typing_error {loc = d_mere.loc ;
      msg = "On attendait une classe et non une interface"}) ;
    if (IdSet.mem id_m env_typage.paramstype)
    then raise (Typing_error {loc = d_mere.loc ;
      msg = "Une classe ne peut étendre un de ses paramstype, beurk"}) ;
    verifie_bf (Jntype d_mere) env_typage ; 
       
    (* Déclaration du corps : des champs, des méthodes et du constructeur  *)
    let body = Hashtbl.find c_body id_c in
    let methodes : methtab = Hashtbl.create 5 in
    let champs : chtab = Hashtbl.create 5 in
    (* J'ai fait le choix après de nombreux essais, d'utiliser des methtab et des
       chtab pour pouvoir 1) retrouver les methodes/champs rapidement pendant
       la vérification des corps (les accès) (d'où l'abandon des MethSet),
       et 2) pour pouvoir en rajouter facilement (d'où des Hashtbl et non des Map) *)
    (* Héritage *)
    heritage_d'une_surci id_c loc_c methodes env_typage true d_mere;
    let id_nouvelles_meths = ref IdSet.empty in
    (* Pour vérifier qu'on ne redéfinit pas deux fois une méthode au sein de la classe *)
    let Ntype (id_m,l_ntypes_m) = d_mere.desc in
    let sigma = fait_sigma id_m d_mere.loc l_ntypes_m in
    Hashtbl.iter
      (fun nom (champ : info_champ) -> 
        Hashtbl.add champs nom 
         {nom = champ.nom ; id_c = champ.id_c ;
          typ = substi_dj sigma champ.typ } )
      (Hashtbl.find env_typage_global.champs id_m) ;

    (* Nouveaux *)
    let verifie_decl (decl : decl desc) = match decl.desc with
      | Dchamp (dj,nom) ->
          let champ = {nom = nom ; id_c = id_c ; typ = dj} in
          begin match (Hashtbl.find_opt champs nom) with
          | None -> 
            verifie_bf dj.desc env_typage;
            Hashtbl.add champs nom champ
          | Some ch ->
            if ch.id_c = id_c then raise (Typing_error {loc = decl.loc ;
              msg = nom ^ " est définit deux fois dans " ^ id_c ^ " c'est interdit."}) ;
            if ch.typ.desc <> dj.desc then raise (Typing_error {loc = decl.loc ;
              msg = id_c ^ " hérite déjà d'un champ " ^ nom 
                ^ " il est interdit de rédéfinir un champ \
                    (excepté en gardant exactement le même type)."})
          end

      | Dmeth dmeth ->
          let d_proto = dmeth.desc.info in 
          let pro = d_proto.desc in (* les deux desc sont redondants ! *)
          if IdSet.mem pro.nom !id_nouvelles_meths
          then raise (Typing_error {loc = d_proto.loc ;
            msg = "Dans pjava il est interdit de définir deux fois une méthode \
                   au sein d'une classe"})
          else id_nouvelles_meths := IdSet.add pro.nom !id_nouvelles_meths ;
          verifie_et_fait_methode pro.typ pro.nom pro.params id_c
            d_proto.loc env_typage methodes ;
      
      | Dconstr dconstr ->
          if Hashtbl.mem c_constr id_c 
          then raise (Typing_error {loc = decl.loc ;
            msg = "Une classe ne peut avoir plus d'un constructeur"}) ;
          let {nom ; params} = dconstr.desc in
          if nom <> id_c then raise (Typing_error {loc = decl.loc ;
            msg = "Le constructeur doit avoir le même nom que la classe"}) ;
          verifie_parametres env_typage params ;
          Hashtbl.add c_constr id_c params 
    in
    List.iter verifie_decl body ; 
    if not (Hashtbl.mem c_constr id_c)
    then Hashtbl.add c_constr id_c [] ;
    Hashtbl.add env_typage_global.champs id_c champs ;
    Hashtbl.add env_typage_global.methodes id_c methodes ;
    (* Informations qui partent dans le GLOBAL *)

    (* Vérification des implements :
       Enfin, on vérifie vraiment si c présente les méthodes demandées *)
    let implements = Hashtbl.find env_typage.implements id_c in
    List.iter (verifie_bf_et_i env_typage) implements ;
    let verification_implements (di : ntype desc) =
      let Ntype (id_i,l_ntypes_i) = di.desc in
      let meth_demandees = recup_methodes di env_typage_global in
      let verifie_meth nom (meth_i : info_methode) = 
        match Hashtbl.find_opt methodes nom with
        | None -> raise (Typing_error {loc = di.loc ;
            msg = id_c ^ " n'implémente pas " ^ id_i 
              ^ " parce qu'elle n'a pas de méthode " ^ nom})
        | Some meth_c -> 
            verifie_meme_parametres meth_i meth_c di.loc ;
            verifie_sous_type_opt meth_c.typ di.loc meth_i.typ env_typage
      in
      Hashtbl.iter verifie_meth meth_demandees 
    in
    List.iter verification_implements implements ;

    (* L'env_typage local a largement été complété, modifié par effet de bord *)
  in
  
  (* En premier *)
  List.iter verifie_classe (List.tl !list_cl) ; (* on ne vérifie pas Object *) 

  (* PUIS *)
  List.iter
    (fun id_c -> 
      let env_typage = Hashtbl.find env_locaux id_c in
      env_typage.methodes <- Hashtbl.copy env_typage_global.methodes ; 
      env_typage.champs <- Hashtbl.copy env_typage_global.champs ;
      (* Des Hashtbl de methtbl. On doit copy les Hashtbl, mais les methtbl peuvent
         être les mêmes !
         On actualise, en prennant toutes les méthodes des vraies ci,
         sachant qu'on ne risque pas d'écraser quoique ce soit, dans les env_locaux
         ces champs étaient restés vides jusqu'ici. *)
      recup_champs_methodes_paramstype id_c env_typage)
    (List.tl !list_cl) ;

  (* ================================= *)
  (* ================================= *)



  (* ===== VERIFICATION DES CORPS ===== *)
  (* Il nous reste à vérifier les corps, composés d'inscrutions. Pour cela on utilise
     en plus des env_typage (locaux), des env_vars une info_var IdMap.t 
     qui pour une variable locale donne son jtype et si elle est initialisée. 
     Ce booléen sert si on déclare une variable avec "I x;"
     "x" sera toujours de type I une interface, mais il faut lui trouver son type
     effectif, sinon que faire si on demande x.m() (même si l'interface I demande m();)

     Mais on ne peut pas garder le type effectif, car on ne le connait pas forcément :
     << I c;
        if (b) {c = new C(7);}
          {c = new A(4);}
      System.out.print(c.m());>>
     Selon la valeur de b, on utilise une méthode différente !

     On voit ici une autre difficulté, c peut être initialisée sous condition !
     Et là ça devient obscure, en effet si c est initialisée dans les deux options 
     (b true ou false), c'est toujours ok. En revanche si c est initilisée dans une 
     seule option, et si b est true ou false, alors on peut quand même considérer
     que c est toujours initialisée. Ahhhhhhhhhhhhhhhhhhhhhh

     Donc pour le coup j'ai besoin d'une Map, pour pouvoir chercher dans les deux branches
     voir quelles variables sont initialisées. Si certaines étaient dans la map mère,
     non initialisées, et qu'elles sont maintenant initialisées dans les deux chemins,
     alors elles deviennent initialisées dans la map mère.
     Pour b = true ou b = false, je fais un cas particulier.
     Il faut gérer les while de même.

     Ça se complique encore davantage avec ce genre de chose :
     << I c;
        int n = (c = new C(7)).m(); >>

     Voir tests_perso/test11.java pour plus d'exemples.

     J'utilise donc trois fonctions : jtype_of_acces, jtype_of_expr, jtype_of_expr_s
     qui renvoie un triplet (nom_var,jtype option,env_vars) 
     (excepté pour jtype_of_acces, voir plus bas)
      - nom_var renseigne le nom de la variable dont on parle: 
        - si c'est une variable on utilise le constructeur Nom of ident
        - si c'est un objet primitif, on utilise Muet (par exemple pour 42 ou null)
        - enfin si c'est un objet juste créé on utilise New
      - Some le jtype de ce dont on parle, None si void
      --> J'ai hate de passer les jtype option en Jvoid
      - La nouvelle Map env_vars (on a pu initialiser des variables)

     Exemple : 
     - pour (adrien.ville_natale.nb_d'habitants = 700) on renvoie (Nom "adrien",Some int)
     - pour (new C(7)).m() on renvoie (New,type de retour de m dans C) 

     Il faut aussi penser à produire l'arbre de sortie, cf mon dernier pavé.
     J'ai entièrement fini le typeur avant de me soucier de la sortie, donc 
     toutes mes remarques omettent l'arbre de sortie. *)

  (* Pour l'arbre de sortie j'ai notamment besoin de la première vraie classe
     parent d'un ntype, à savoir la classe elle même si c'est une vraie classe, 
     ou un parent si c'est un ntype. *)

  let rec vraie_c env_typage id_ct = 
    if IdSet.mem id_ct env_typage_global.c then id_ct
    else (
      let dc_mere = List.hd (Hashtbl.find env_typage.extends id_ct) in
      let Ntype(id_m,_) = dc_mere.desc in
      vraie_c env_typage id_m )
  in


  (* === LES ACCES === *)
  let rec jtype_of_acces loc_acc env_typage env_vars b = function
    (* b : true si on demande quelque chose de modifiable : un champ ou une variable,
       faux sinon, ie si on demande une méthode.
       J'aurais pu faire deux fonctions complètement séparées.

       Cette fonction renvoie finalement un quadruplet 
       (nom_var,jtype option,jtype desc list , env_vars) :
         - Son nom (pour le coup toujours un Nom of ident)
         - Le type de la variable à laquelle on accède. (Pour un champ, le type du champ,
         pour une méthode, le type de retour de la méthode ! Potentiellement void... )
         - La liste types_params dans le cas d'une méthode, [] sinon
         - La nouvelle Map env_vars, car dans l'expr_simple on a pu la modifier *)
    | Aident id ->
      if b then 
        begin match (IdMap.find_opt id env_vars) with
        | Some {jt} -> (Nom id,Some jt,None ,[],env_vars) , (T_Aident id)
        | None -> 
          begin match (IdMap.find_opt "this" env_vars) with
          | Some {jt = Jntype dn} -> 
            let Ntype(id_c,_) = dn.desc in
            let champs = Hashtbl.find env_typage.champs id_c in
            begin match (Hashtbl.find_opt champs id) with
            | Some info_ch -> (Nom "this",Some info_ch.typ.desc , None ,[],env_vars) 
                , (T_Achemin_ch ((T_Ethis , id_c), id))
            | None -> raise (Typing_error {loc = loc_acc ;
              msg = id ^ " est inconnue, ni une variable local, ni un champ de this"})
            end
          | _ (*None*) -> raise (Typing_error {loc = loc_acc ;
              msg = id ^ " est inconnue: pas une variable local et il n'y a pas de this \
                    dans le contexte actuel (probablement Main)"})
          end
        end
      else
        begin match (IdMap.find_opt "this" env_vars) with
        | Some {jt = Jntype dn} ->
          let Ntype(id_c,_) = dn.desc in
          let methodes = Hashtbl.find env_typage.methodes id_c in
          begin match (Hashtbl.find_opt methodes id) with
          | None -> raise (Typing_error {loc = loc_acc ;
              msg = id ^ " n'est pas une méthode de this."})
          | Some info_meth -> 
            let type_r = (match info_meth.typ with None -> None | Some dj -> Some dj.desc) in
            let jt_params = 
              List.map (fun (dj : jtype desc) -> dj.desc) info_meth.types_params in
            (Nom "this", type_r , None , jt_params , env_vars) 
            , (T_Achemin_meth (T_Ethis , id))
            (* ici pas besoin de substituer, car l'env_typage de this est l'env actuel *)
          end

        | _ -> raise (Typing_error {loc = loc_acc ;
          msg = id ^ " est une méthode inconnue, car il n'y a pas de this dans \
                le contexte actuel (probablement Main). Il faut indiquer l'objet \
                sur laquelle elle s'applique."})
        end
    
    | Achemin (dexpr_s,id) ->
      let info_typage , typed_expr = 
        jtype_of_expr_s dexpr_s.loc env_typage env_vars dexpr_s.desc in
      begin match info_typage with
      (* ce qu'on nous donne est initialisé ! *)
      | (nom_var, Some (Jntype dn) ,env_vars') ->
        let Ntype (id_ci,l_ntypes_ci) = dn.desc in
        let sigma = fait_sigma id_ci dn.loc l_ntypes_ci in
        (* On pourrait l'enregistrer dans env_vars... *)
        if b then
          if not (IdSet.mem id_ci env_typage.c)
          then raise (Typing_error {loc = dexpr_s.loc ;
            msg = "Est de type " ^ id_ci ^ " qui n'est pas une classe (ou un paramtype), \
                   et donc ne possède pas de champs (probablement une interface)"})
          else begin
          let champs = Hashtbl.find env_typage.champs id_ci in 
          begin match (Hashtbl.find_opt champs id) with
          | None -> raise (Typing_error {loc = loc_acc ;
              msg = id_ci ^ " ne possède pas de champ " ^ id })
          | Some champ ->
              (nom_var,Some (substi_jt sigma champ.typ.desc),None,[],env_vars') ,
              (T_Achemin_ch ((typed_expr , (vraie_c env_typage id_ci)), id))
          end end
        else begin
          let methodes = Hashtbl.find env_typage.methodes id_ci in
          begin match Hashtbl.find_opt methodes id with
          | None  -> raise (Typing_error {loc = loc_acc ;
              msg = id_ci ^ " ne possède pas de méthode " ^ id })
          | Some meth -> 
            (*AHHHHH Il faut que j'arrête avec ces jtype desc option déjà jtype option desc
            serait plus pratique, mais finalement je veux un Jvoid et un Jstring. *)
            (* On utilise sigma, pour ramener cette méthode dans l'env_typage actuel *)
            let type_r = begin match (substi_djo sigma meth.typ) with
            | None -> None
            | Some dj -> Some dj.desc end in
            let jt_params = 
              List.map (fun (dj : jtype desc) -> (substi_dj sigma dj).desc)
              meth.types_params in
            (nom_var , type_r , Some dn, jt_params , env_vars' ) ,
            (T_Achemin_meth (typed_expr,id))
          end end
      
      | (_,_,_) -> raise (Typing_error {loc = dexpr_s.loc ;
            msg = "Les types primitifs n'ont pas de méthodes ou de champs" })
      end


  (* === LES EXPRESSIONS === *)
  (* Le <acces> = <expr> apparait aussi dans les instructions, donc je fais
     une fonction auxiliaire pour ne pas l'écrire deux fois. *)
  and acces_equal_expr env_typage env_vars (dacces : acces desc) (dexpr : expr desc) loc =
    let ((_,jo_expr,env_vars'),typed_expr) = 
      jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
    let ((nom_var, jo_acces, _ , _ , env_vars''),typed_acces) = 
      jtype_of_acces dacces.loc env_typage env_vars' true dacces.desc in
    (* J'ai fait env_vars -> env_vars' via l'expr -> env_vars'' via l'accès
       Mais je n'ai pas vérifié le comportement de java, peut-être que
       pour gérer l'accès on n'a pas les infos d'initialisation hérité de l'expr *)
    (* C'est l'occasion d'initialiser la variable si ce n'est déjà fait ! *)
    let env_vars''' = begin match nom_var with
    | Nom id_var ->
        let info_var = IdMap.find id_var env_vars'' in
        IdMap.add id_var {jt = info_var.jt ; init = true} env_vars'' 
        (* On écrase l'ancienne 
         Remarque : J'ai voulu rajouter un test "if jo_expr <> Some Jtypenull"
         en prenant mes libertés par rapport à java, qui considère ça comme
         une initialisation acceptable, mais plante à l'execution si on essaye
         d'accéder aux champs...
         Finalement j'ai vraisemblablement tord puis que exec-fail/null1 
         verifie ce comportement. Je suppose que c'est pratique de travailler
         avec des variables null. *)
    | _ -> raise (Typing_error {loc = dacces.loc ;
        msg = "On ne peut pas modifier des valeurs, il faut nommer les variables !"}) 
    end in
    (* === *)
    begin match jo_expr,jo_acces with
    | None,None -> ()
    | Some jt_expr,Some jt_acces ->
        if not (sous_type jt_expr jt_acces env_typage)
        then raise (Typing_error {loc=loc ;
          msg = "Pour changer une valeur, il faut un sous-type de ce qui est demandé "
              ^ (str_of_jtp jt_expr) ^ " n'est pas un sous-type de "
              ^ (str_of_jtp jt_acces)})
    | _,_ -> raise (Typing_error {loc=loc ;
          msg = "Pour changer une valeur, il faut un sous-type de ce qui est demandé "
              ^ (str_of_jo jo_expr) ^ " n'est pas un sous-type de "
              ^ (str_of_jo jo_acces)})
    end ;
    (nom_var,jo_acces,env_vars'''),(typed_acces,typed_expr)


  (* Pour toutes les autres expressions *)
  and jtype_of_expr loc_expr env_typage env_vars = function
    | Enull -> (Muet,Some Jtypenull,env_vars),T_Enull
    | Esimple dexpr_s -> jtype_of_expr_s dexpr_s.loc env_typage env_vars dexpr_s.desc
    | Eequal (dacces,dexpr) -> (* permet a = b = c qui change b en c puis a en b *)
        let info_typage, (typed_a,typed_e) = 
          acces_equal_expr env_typage env_vars dacces dexpr loc_expr in
        info_typage , (T_Eequal (typed_a,typed_e))
    | Eunop (unop,dexpr) -> 
        let (_,jo_expr,env_vars'),typed_expr = 
          jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
        (* Si c'est bien un Jint ou un Jboolean, on passe forcément en Muet *)
        begin match unop with
          | Unot -> 
              if jo_expr <> (Some Jboolean) 
              then raise (Typing_error {loc=dexpr.loc ;
                msg = "Le not s'applique sur un boolean"}) ;
              (Muet, Some Jboolean , env_vars') , (T_Eunop (T_Unot , typed_expr))
          | Uneg ->
              if jo_expr <> (Some Jint) 
              then raise (Typing_error {loc=dexpr.loc ;
                msg = "Le moins unaire s'applique sur un entier"}) ;
              (Muet, Some Jint , env_vars') , (T_Eunop (T_Uneg , typed_expr))
        end
    | Ebinop (dexpr1,binop,dexpr2) ->
        let (_,jo_expr1,env_vars'),typed_expr1 = 
          jtype_of_expr dexpr1.loc env_typage env_vars dexpr1.desc in
        let (_,jo_expr2,env_vars''),typed_expr2 = 
          jtype_of_expr dexpr2.loc env_typage env_vars' dexpr2.desc in
        (* idem on peut passer en Muet *)
        (* j'ai fait env_vars -> env_vars' via l'expr 1 -> env_vars'' via l'expr2
           pour suivre l'idée d'évaluation paresseuse, mais je n'ai pas vérifier
           Il est fort probable qu'il faille faire env_vars -> env_vars1 et env_vars2
           pour ensuite les fusionner. *)
        let typed_expr1 = ref typed_expr1 in 
        let typed_expr2 = ref typed_expr2 in 
        let jt,typed_op = match jo_expr1,jo_expr2 with
        | Some jt_expr1,Some jt_expr2 ->
          begin match jt_expr1,binop,jt_expr2 with
          | Jint,Badd,Jint -> Jint,T_Badd_int     | Jint,Bsub,Jint -> Jint,T_Bsub
          | Jint,Bmul,Jint -> Jint,T_Bmul         | Jint,Bdiv,Jint -> Jint,T_Bdiv
          | Jint,Bmod,Jint -> Jint,T_Bmod         | Jint,Blt,Jint -> Jboolean,T_Blt
          | Jint,Ble,Jint -> Jboolean,T_Ble       | Jint,Bgt,Jint -> Jboolean,T_Bgt
          | Jint,Bge,Jint -> Jboolean,T_Bge
          | Jboolean,Band,Jboolean -> Jboolean,T_Band 
          | Jboolean,Bor,Jboolean -> Jboolean,T_Bor
          | (Jntype {desc=Ntype("String",[])} as s),Badd,(Jntype {desc=Ntype("String",[])})  
            -> s,T_Bconcat
          | (Jntype {desc=Ntype("String",[])} as s),Badd,Jint 
            -> typed_expr2 := T_Eunop (T_Uconvert , !typed_expr2) ; s,T_Bconcat
          | Jint,Badd,(Jntype {desc=Ntype("String",[])} as s)  
            -> typed_expr1 := T_Eunop (T_Uconvert , !typed_expr1) ; s,T_Bconcat
          | Jtypenull,Beq,Jntype _  | Jntype _,Beq,Jtypenull  -> Jboolean,T_Beq
          | Jtypenull,Bneq,Jntype _ | Jntype _,Bneq,Jtypenull -> Jboolean,T_Bneq
          | _,Beq,_ | _,Bneq,_ ->
              (* Il y a une erreur dans l'énoncé, on nous dit que cette expression est 
                 correcte ssi les deux types sont équivalents, mais null a un role 
                 particulier, il n'est pas équivalent mais pourtant on doit l'accepter 
                 si il est comparé à un ntype. *)
              verifie_sous_type jt_expr1 dexpr1.loc jt_expr2 env_typage ;
              verifie_sous_type jt_expr2 dexpr2.loc jt_expr1 env_typage ;
              Jboolean , (if binop = Beq then T_Beq else T_Bneq)
          | _,_,_ -> raise (Typing_error {loc = dexpr1.loc ;
              msg = "Cette opérateur binaire ne s'applique pas avec ces types "
                   ^ (str_of_jtp jt_expr1) ^ " et " ^ (str_of_jtp jt_expr2)})
            (* Ce message d'erreur est terrible...
               On pourrait demander un binop desc pour commencer. *)
          end
        | _,_ -> raise (Typing_error {loc = loc_expr ;
            msg = "Les opérations ne s'appliquent pas avec des expressions de type void"})
        in
        (Muet,Some jt,env_vars'') , (T_Ebinop (!typed_expr1 , typed_op , !typed_expr2))



  (* === LES EXPRESSIONS SIMPLES === *)
  (* Pour utiliser une méthode ou un constructeur, on doit vérifier que les
     paramètres données conviennent, voilà la fonction auxiliaire qui s'en occupe.
     Elle renvoie le nouvel env_vars, car on a pu initialiser des variables.
     Et comme partout, le nouvel arbre de sortie (que je ne mentionne jamais). *)
  and verifie_parametres_effectifs env_typage env_vars loc_appli jt_params 
    (l_dexpr : expr desc list) = match jt_params , l_dexpr with
    | [],[] -> env_vars,[]
    | [],_ -> raise (Typing_error {loc = loc_appli ;
      msg = "La méthode (ou le constructeur) est appelée sur trop de paramètres"})
    | _,[] -> raise (Typing_error {loc = loc_appli ;
      msg = "La méthode (ou le constructeur) est appelée sur pas assez de paramètres"})
    | jt_demande :: q_jtp , dexpr_donnee :: q_expr ->
      let (_,jo_expr_donnee,env_vars'),typed_expr_donnee = 
        jtype_of_expr dexpr_donnee.loc env_typage env_vars dexpr_donnee.desc in
      begin match jo_expr_donnee with
      | None -> raise (Typing_error {loc = dexpr_donnee.loc ;
        msg = "Cette expression est de type void, ce qui n'est jamais un \
               paramètre recevable pour une méthode (ou un constructeur) !"})
      | Some jt_donnee -> verifie_sous_type jt_donnee dexpr_donnee.loc jt_demande env_typage
      end ;
      let env_vars'' , typed_expr_l = 
        verifie_parametres_effectifs env_typage env_vars' loc_appli q_jtp q_expr in
      (env_vars'' , typed_expr_donnee :: typed_expr_l)

  (* La fonction générale pour toutes les expressions simples : *)
  and jtype_of_expr_s loc_expr_s env_typage env_vars = function
    | ESint n -> (Muet,Some Jint,env_vars) , (T_Eint n)
    | ESstr s -> 
        (Muet,Some (Jntype {loc = loc_dum ; desc=Ntype("String",[])}),env_vars) , (T_Estr s)
        (* Il faut absoluement que je fasse un Jstring, ça sera tellement plus simple *)
    | ESbool b -> (Muet,Some Jboolean,env_vars),(T_Ebool b)
    | ESthis ->
      begin match (IdMap.find_opt "this" env_vars) with
      | None -> raise (Typing_error {loc = loc_expr_s ;
          msg = "Aucun this actuellement, probablement parce que dans Main"})
      | Some {jt} -> (Nom "this",Some jt,env_vars), T_Ethis
      end
    | ESexpr dexpr -> jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc 
    | ESnew (dn,l_dexpr) ->
        verifie_bf (Jntype dn) env_typage ;
        let Ntype(id_c,l_ntypes) = dn.desc in
        if id_c = "Object"
        then begin if l_ntypes = [] 
          then ((New , Some (Jntype dn),env_vars), T_Enew ("Object",[]))
          else raise (Typing_error {loc = dn.loc ;
            msg = "Le constructeur Object() n'attend pas de paramètre"}) end
        else begin match Hashtbl.find_opt c_constr id_c with
          | None -> raise (Typing_error {loc = dn.loc ;
              msg = id_c ^ " ne possède pas de constructeur, est-ce bien une classe \
                et non interface ou un paramtype par exemple" })
          | Some params_constr ->
              let sigma = fait_sigma id_c dn.loc l_ntypes in
              let jt_params = 
                List.map (fun (dp : param desc) -> (substi_jt sigma dp.desc.typ.desc)) 
                params_constr in
              let env_vars',typed_l_expr = verifie_parametres_effectifs 
                env_typage env_vars loc_expr_s jt_params l_dexpr in
              (New , Some (Jntype dn) , env_vars') , (T_Enew (id_c , typed_l_expr))
        end

    | ESacces_meth (dacces,l_dexpr) ->
        (* C'est ici que je fais les cas particuliers System.out.print(<str>) et println *)
        let env_vars_special = ref env_vars in
        let print = ref "print" in
        let typed_expr_print = ref (T_Estr "") in
        if begin match dacces.desc with
        | Achemin (dexpr_s,print') when (print' = "print" || print' = "println") ->
          print := print' ;
          begin match dexpr_s.desc with
          | ESacces_var {desc = 
              Achemin ({desc = ESacces_var {desc = Aident "System"}},"out")} ->
            begin match l_dexpr with
            | [dexpr] ->
              let (_,jo_expr,env_vars') ,typed_expr =
                jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
              typed_expr_print := typed_expr ;
              env_vars_special := env_vars' ;
              begin match jo_expr with
              | Some (Jntype {desc=Ntype("String",[])}) -> true
              | _ -> raise (Typing_error {loc = dexpr.loc ;
                msg = "System.out.print et println attendent un String"})
              end
            | _ -> raise (Typing_error {loc = dacces.loc ;
              msg = "System.out.print et println attendent un unique paramètre (un String)"})
            end
          | _ -> false
          end
        | _ -> false end
        then ((Muet , None, !env_vars_special) ,
            (if !print = "print" then T_Eprint !typed_expr_print 
             else T_Eprintln !typed_expr_print))
        (* === Fin de System.out.print === *)

        else begin 
        let (nom_var,jo_acces,dno_type_expr,jt_params,env_vars'),typed_acces = 
          jtype_of_acces dacces.loc env_typage env_vars false dacces.desc in
        begin match nom_var with
        | Muet | New -> ()
        | Nom id -> 
          let {init} = IdMap.find id env_vars in
          if not init then raise (Typing_error {loc = loc_expr_s ;
            msg = id ^ " n'est peut-être pas initialisée, il faut qu'elle soit plus \
                  clairement initialisée." })
        end ;
        let env_vars'',typed_l_expr = 
          verifie_parametres_effectifs env_typage env_vars' loc_expr_s jt_params l_dexpr in
        
        (* Finalement pour la production de code, nous avons décidé de séparer
           la méthode equals de la classe String des autres ici.
           Dans les faits, ce serait mieux de tout refaire au sujet des String. *)
        let typed_expr_str = ref (T_Estr "") in
        if begin match dno_type_expr,typed_acces with
        | Some ({desc=Ntype("String",[])}) , T_Achemin_meth (typed_expr,"equals") 
        -> typed_expr_str := typed_expr ; true
        | _ -> false end
        then ((nom_var,jo_acces,env_vars''), 
          T_Estr_equal (!typed_expr_str , List.hd typed_l_expr))
        else ((nom_var,jo_acces,env_vars''),
          T_Eacces_meth (typed_acces , typed_l_expr))
        end

    | ESacces_var dacces ->
        let (nom_var,jo_acces,_,_,env_vars'),typed_acces = 
          jtype_of_acces dacces.loc env_typage env_vars true dacces.desc in
        begin match nom_var with
        | Muet | New -> ()
        | Nom id -> 
          let {init} = IdMap.find id env_vars in
          if not init 
          then raise (Typing_error {loc = loc_expr_s ;
            msg = id ^ " n'est peut-être pas initialisée, il faut qu'elle soit plus \
                  clairement initialisée." })
        end ;
        (nom_var,jo_acces,env_vars'),T_Eacces_var typed_acces
  in
  

  (* === LES INSTRUCTIONS === *)
  (* verifie_bloc_instrs renvoie un booléen, indiquant si on a bien trouvé un return
     comme attendu, et un nouvel env_vars, car on peut initialiser des variables locales
     dans des sous (bloc) instructions.
     Avant de réaliser mon erreur grace aux tests (ABR.java), je me contentais de planter
     si on atteignait la fin du bloc sans avoir reçu de return.
     MAIS il ne faut pas ! Car peut-être qu'on était dans un sous-bloc, et que le bloc 
     principal va faire le return. J'utilise donc une deuxième fonction, qui appelle 
     verifie_bloc_instrs et plante si on reçoit un false. *)

  let rec verifie_bloc_instrs (type_r : jtype desc option) loc_bloc 
        env_typage env_vars (instrs : instr desc list) = match instrs with
    | [] -> (false , env_vars) , []
      (* Si on attendait un return, on en a pas trouvé. 
         Mais si type_r = None ce n'est pas grave. *)
      (* On renvoie l'env_vars, pour récupérer les initialisations
         de variables au sein de sous bloc d'instructions *)

    | dinstr :: q -> 
      begin match dinstr.desc with
      | Ireturn dexpr_opt ->
        let djo,env_vars',typed_expr_opt = match dexpr_opt with 
          | None -> None,env_vars,None
          | Some dexpr ->
            let (_,jo_expr,env_vars'),typed_expr = 
              jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
            begin match jo_expr with
            | None -> None
            | Some jt -> Some {loc = dexpr.loc ; desc = jt}
            end (* foutu jtype desc option *) , env_vars' , Some typed_expr
        in
        verifie_sous_type_opt djo dinstr.loc type_r env_typage ;
        (* Il faudrait VRAIMENT rattraper l'erreur, et préciser que c'est 
           pour faire office de type de retour *)
        (true , env_vars') , [T_Ireturn typed_expr_opt]
      (* Au début j'ai voulu séparer Ireturn du reste, pour n'écrire 
         << verifie_bloc_instrs type_r loc_bloc env_typage env_vars q >>
         qu'une fois, mais parfois l'env_vars change ! 
         J'aurais pu faire renvoyer env_vars' au matching*)
      
      | Inil -> 
        let info_typage, typed_list = 
          verifie_bloc_instrs type_r loc_bloc env_typage env_vars q in
        info_typage, (T_Inil :: typed_list)

      | Isimple dexpr_s -> 
        let (_,_,env_vars'),typed_expr = 
          jtype_of_expr_s dexpr_s.loc env_typage env_vars dexpr_s.desc in
        (* Attention, ici on autorise ce genre de chose pour simplifier la
           grammaire, mais en java c'est interdit, d'ailleurs on ignore le retour
           excepté la modification de l'env_envars *)
        let info_typage , typed_list = 
          verifie_bloc_instrs type_r loc_bloc env_typage env_vars' q in
        info_typage , (T_Isimple typed_expr) :: typed_list

      | Iequal (dacces,dexpr) ->
        let (_,_,env_vars'),(typed_a,typed_e) = 
          acces_equal_expr env_typage env_vars dacces dexpr dinstr.loc in
        let info_typage , typed_list = 
          verifie_bloc_instrs type_r loc_bloc env_typage env_vars' q in
        info_typage , (T_Iequal (typed_a,typed_e)) :: typed_list
      
      | Idef (dj,id) ->
        begin match IdMap.find_opt id env_vars with
        | Some _ -> raise (Typing_error {loc = dinstr.loc ;
          msg = "Il est interdit de redéfinir une variable"})
        | None ->
          let env_vars' = IdMap.add id {jt = dj.desc ; init = false} env_vars in
          let info_typage , typed_list = 
            verifie_bloc_instrs type_r loc_bloc env_typage env_vars' q in
          info_typage , (T_Idef id) :: typed_list
        end

      | Idef_init (dj,id,dexpr) ->
        let (_,jo_expr,env_vars'),typed_expr = 
          jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
        begin match jo_expr with
        | None -> raise (Typing_error {loc = dexpr.loc ;
          msg = "Problème pour initialiser " ^ id ^ "on attendait une valeur de type " 
              ^ (str_of_jtp dj.desc) ^ " et on a reçu un type Void" })
        | Some jt_expr -> verifie_sous_type jt_expr dexpr.loc dj.desc env_typage
        end ;
        begin match IdMap.find_opt id env_vars' with
        | Some _ -> raise (Typing_error {loc = dinstr.loc ;
          msg = "Il est interdit de redéfinir une variable"})
        | None ->
          let env_vars' = IdMap.add id {jt = dj.desc ; init = true} env_vars' in
          let info_typage , typed_list = 
            verifie_bloc_instrs type_r loc_bloc env_typage env_vars' q in
          info_typage , (T_Idef_init (id,typed_expr)) :: typed_list
        end
        (* On pourrait faire une fonction auxiliaire pour éviter de se répéter *)

      | Iif(dexpr,dinstr1,dinstr2) ->
        let (_,jo_expr,env_vars'),typed_expr 
          = jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
        (* OUI au passage on a pu initialiser des variables, on retient le nouvel env_vars :
           << boolean b2 ; boolean b = true;
              if (b2 = b) {}
              System.out.print(b2); >>
           Est correcte, cf tests_perso/test12.java *)
        (* J'ai mis les cas particulier avec true ou false, la vérification paresseuse *)
        if jo_expr <> Some Jboolean 
        then raise (Typing_error {loc = dexpr.loc ;
          msg = "La condition d'un if doit être un booléen !" }) ;
        let (r,env_vars'',typed_instr1,typed_instr2) = begin match dexpr.desc with
        | Esimple {desc = ESbool true} ->
          let (r1,env_vars1),typed_linstr1 = 
            verifie_bloc_instrs type_r dinstr1.loc env_typage env_vars' [dinstr1] in
          (* les typed_linstr1 sont des listes à nécessairement un élément *)
          r1 , IdMap.mapi (fun id _ -> IdMap.find id env_vars1) env_vars' ,
          (List.hd typed_linstr1), T_Inil
          (* On ne veut pas des nouvelles variables locales, en revanche on est preneur
             des initialisations. *)
        | Esimple {desc = ESbool false} ->
          let (r2,env_vars2),typed_linstr2 = 
            verifie_bloc_instrs type_r dinstr2.loc env_typage env_vars' [dinstr2] in
          r2 , IdMap.mapi (fun id _ -> IdMap.find id env_vars2) env_vars' ,
          T_Inil , (List.hd typed_linstr2)
        | _ ->
          let (r1,env_vars1),typed_linstr1 = 
            verifie_bloc_instrs type_r dinstr1.loc env_typage env_vars' [dinstr1] in
          let (r2,env_vars2),typed_linstr2 = 
            verifie_bloc_instrs type_r dinstr2.loc env_typage env_vars' [dinstr2] in
          r1 && r2 ,
          IdMap.mapi 
            (fun id _ ->
              let info1 = IdMap.find id env_vars1 in
              let info2 = IdMap.find id env_vars2 in
              {jt = info1.jt ; init = (info1.init && info2.init)})
            env_vars' ,
          (List.hd typed_linstr1) , (List.hd typed_linstr2)
          end in
        if r then (* Les deux chemins fournissent un return ! *)
          ((true,env_vars''), [T_Iif (typed_expr,typed_instr1,typed_instr2)] )
        else (
          let info_typage , typed_list = 
            verifie_bloc_instrs type_r loc_bloc env_typage env_vars'' q in
          (info_typage , (T_Iif (typed_expr,typed_instr1,typed_instr2) ) :: typed_list))

      | Iwhile(dexpr,dinstr') ->
        let (_,jo_expr,env_vars'),typed_expr = 
          jtype_of_expr dexpr.loc env_typage env_vars dexpr.desc in
        if jo_expr <> Some Jboolean 
        then raise (Typing_error {loc = dexpr.loc ;
          msg = "La condition d'un while doit être un booléen !" }) ;
        let typed_instr_w = List.hd (snd (
          verifie_bloc_instrs type_r dinstr'.loc env_typage env_vars' [dinstr'])) in
        (* On ne peut pas faire confiance au while pour initialiser des variables, donc
           on ne fait rien du nouvel env_vars, de même pour le return. 
           Ainsi, on se fiche de savoir si un return a été trouvé. En revanche si il 
           en trouve un, alors il faut qu'il soit de type type_r. *)
        let info_typage , typed_list = 
          verifie_bloc_instrs type_r loc_bloc env_typage env_vars' q in
        info_typage , (T_Iwhile (typed_expr, typed_instr_w)) :: typed_list

      | Ibloc(l_dinstrs) ->
        let (rb,env_vars_bloc),typed_sous_list = 
          verifie_bloc_instrs type_r dinstr.loc env_typage env_vars l_dinstrs in
        (* Comme pour les if, on est preneur des initialisations. *)
        let env_vars' = IdMap.mapi (fun id _ -> IdMap.find id env_vars_bloc) env_vars in
        if rb then (* Si le return a été trouvé on arrête *)
          ((true,env_vars') , [T_Ibloc typed_sous_list])
        else (
          let info_typage , typed_list =
            verifie_bloc_instrs type_r loc_bloc env_typage env_vars' q in
          (info_typage , (T_Ibloc typed_sous_list) :: typed_list) )
      end 
  in
  let verifie_bloc_instrs_effectif type_r loc_bloc env_typage env_vars l_instrs =
    let (r,_),typed_list = 
      verifie_bloc_instrs type_r loc_bloc env_typage env_vars l_instrs in
    if (not r) && type_r <> None 
    then raise (Typing_error {loc = loc_bloc ;
      msg = "Il manque un return à ces instructions, on attend " ^ (str_of_djo type_r) })
    else typed_list
  in
  
  (* === Fonctions principales === *)
  (* À nouveau, en ce qui concerne l'arbre de sortie, voir le tout dernier pavé. *)
  let tbl_meth = Hashtbl.create 10 in

  let mk_corps_c id_c = 
    let env_typage = Hashtbl.find env_locaux id_c in
    let loc_c = Hashtbl.find env_typage.tab_loc id_c in 
    let body = Hashtbl.find c_body id_c in
    let params_dn = List.map
      (fun (dpt : paramtype desc) ->
        {loc = dpt.loc ; desc = Ntype (dpt.desc.nom,[]) })
      (Hashtbl.find ci_params id_c) in
    let info_this = 
      { jt = Jntype {loc = loc_c ; desc = Ntype (id_c , params_dn)} ; init = true} in
    (* this est une variable spéciale, de type C<T1,...,Tk> *)
    (* Pour l'arbre de sortie : *)
    let methtab = Hashtbl.find env_typage_global.methodes id_c in
    let cle_methodes = Hashtbl.fold 
      (fun id_m (info_m : info_methode) l_cle -> (info_m.id_ci,id_m)::l_cle)
      methtab [] in
    let dc_mere = List.hd (Hashtbl.find env_typage.extends id_c) in
    let Ntype(id_m,_) = dc_mere.desc in

    let id_champs = ref [] in
    let constructeur = ref None in

    let verifie_decl (decl : decl desc) = match decl.desc with
      | Dchamp (_,id_ch) -> id_champs := id_ch :: !id_champs
      | Dmeth dmeth ->
          let env_vars = ref (IdMap.singleton "this" info_this) in
          let meth = dmeth.desc in
          let pro = meth.info.desc in
          let cle_meth = (id_c , pro.nom) in
          let params_id = List.map (fun (dp : param desc) -> dp.desc.nom) pro.params in 
          let type_retour = pro.typ in
          List.iter 
            (fun (dp : param desc) -> env_vars := 
              IdMap.add dp.desc.nom {jt = dp.desc.typ.desc ; init = true} !env_vars )
            pro.params ;
          let typed_list_instrs = verifie_bloc_instrs_effectif 
            type_retour decl.loc env_typage !env_vars meth.body in
          Hashtbl.add tbl_meth cle_meth {params = params_id ; body = typed_list_instrs}
      
      | Dconstr dconstr -> 
          (* On pourrait faire une fonction auxiliaire, on copie le cas précédent *)
          let env_vars = ref (IdMap.singleton "this" info_this) in
          let constr = dconstr.desc in
          let params_id = List.map (fun (dp : param desc) -> dp.desc.nom) constr.params in 
          List.iter 
            (fun (dp : param desc) -> env_vars := 
              IdMap.add dp.desc.nom {jt = dp.desc.typ.desc ; init = true} !env_vars )
            constr.params ;
          let typed_list_instrs = verifie_bloc_instrs_effectif 
            None dconstr.loc env_typage !env_vars constr.body in
          constructeur := Some {params = params_id ; body = typed_list_instrs}
    in
    List.iter verifie_decl body ;
    { nom = id_c ; mere = id_m ; cle_methodes = cle_methodes ; 
      id_champs = !id_champs ; constructeur = !constructeur }
  in
 
  (*Avant je faisais :       
      IdSet.iter verifie_corps_c 
      (IdSet.diff env_typage_global.c (IdSet.of_list ["Object";"String";"Main"])) ;
    Mais je veux garder mon ordre topologique *) 
  let list_cl = List.filter
    (fun id_c -> (id_c <> "Object") && (id_c <> "String")) !list_cl in
  let l_typed_class = 
    {nom = "Object" ; mere = "Object" ; 
     cle_methodes = [] ; id_champs = [] ; constructeur = None }
    :: (List.map mk_corps_c list_cl) in

  (* Enfin, on traite Main *)
  let env_vars = IdMap.empty in
  let loc_main = Hashtbl.find env_typage_global.tab_loc "Main" in
  let typed_main = verifie_bloc_instrs_effectif
    None loc_main env_typage_global env_vars !body_main in

  
  (* == LE NOUVEL ARBRE DE SYNTAXE == *)
  (* Brièvement ce qu'il nous faut pour la production de code
     (pour des explications voir le rapport) :
     - Pour les méthodes :
       Désormais on repère une méthode par une clé :
       (nom de la classe où est son corps , nom de la méthode)
       avec ça on joint une table tbl_meth : cle -> (son corps,les params : ident list)
       La liste des méthodes d'une classe se résume à la liste des clés.
     - Pour les champs :
       On ne garde que la liste des noms des champs.
     - On renvoie la node Objet, pour récupérer l'arbre des héritages des classes.
     - On transforme tout l'arbre de syntaxe des corps, avec des nouveaux types.
       Globalement très semblable, mis à part qu'on fait sauter tous les types
       pûrement informatifs notamment les types paramètres. Ainsi que tous les 
       localisations. Mais aussi les ambiguités, typiquement pour le + (String 
       et/ou int). On sépare également les méthodes des champs dans les accès.
       Voir la fin de Ast_typing.ml pour la liste des types en sortie. 
       Enfin, on veut les classes dans un ordre topologique. *)
  node_obj.succ <- List.filter (fun (n : node) -> n.id <> "String") node_obj.succ ;

  {classes = l_typed_class ;
   main_body = typed_main ; 
   tbl_meth = tbl_meth ;
   node_obj = node_obj}
