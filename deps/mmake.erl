%% 多进程编译,修改自otp/lib/tools/src/make.erl
%% 解析Emakefile,根据获取{mods, options}列表,
%% 按照次序编译每项(解决编译顺序的问题)
%% 其中mods也可以包含多个模块,当大于1个时,
%% 可以启动多个process进行编译,从而提高编译速度.
-module(mmake).
-export([all/1, all/2, files/2, files/3]).

-include_lib("kernel/include/file.hrl").

-define(MakeOpts,[noexec,load,netload,noload]).

all(Worker) when is_integer(Worker) ->
    all(Worker, []).

all(Worker, Options) when is_integer(Worker) ->
    init(),
    {MakeOpts, CompileOpts} = sort_options(Options,[],[]),
    case read_emakefile('Emakefile', CompileOpts) of
        Files when is_list(Files) ->
            do_make_files(Worker, Files, MakeOpts);
        error ->
            error
    end.

files(Worker, Fs) ->
    files(Worker, Fs, []).

files(Worker, Fs0, Options) ->
    Fs = [filename:rootname(F,".erl") || F <- Fs0],
    {MakeOpts,CompileOpts} = sort_options(Options,[],[]),
    case get_opts_from_emakefile(Fs,'Emakefile',CompileOpts) of
	Files when is_list(Files) ->
	    do_make_files(Worker, Files,MakeOpts);	    
	error -> error
    end.

do_make_files(Worker, Fs, Opts) ->
    %io:format("worker:~p~nfs:~p~nopts:~p~n", [Worker, Fs, Opts]),
    process(Fs, Worker, lists:member(noexec, Opts), load_opt(Opts)).

sort_options([H|T],Make,Comp) ->
    case lists:member(H,?MakeOpts) of
	true ->
	    sort_options(T,[H|Make],Comp);
	false ->
	    sort_options(T,Make,[H|Comp])
    end;
sort_options([],Make,Comp) ->
    {Make,lists:reverse(Comp)}.

%%% Reads the given Emakefile and returns a list of tuples: {Mods,Opts}
%%% Mods is a list of module names (strings)
%%% Opts is a list of options to be used when compiling Mods
%%%
%%% Emakefile can contain elements like this:
%%% Mod.
%%% {Mod,Opts}.
%%% Mod is a module name which might include '*' as wildcard
%%% or a list of such module names
%%%
%%% These elements are converted to [{ModList,OptList},...]
%%% ModList is a list of modulenames (strings)
read_emakefile(Emakefile,Opts) ->
    case file:consult(Emakefile) of
	{ok, Emake} ->
	    transform(Emake,Opts,[],[]);
	{error,enoent} ->
	    %% No Emakefile found - return all modules in current 
	    %% directory and the options given at command line
	    Mods = [filename:rootname(F) ||  F <- filelib:wildcard("*.erl")],
	    [{Mods, Opts}];
	{error,Other} ->
	    io:format("make: Trouble reading 'Emakefile':~n~p~n",[Other]),
	    error
    end.

transform([{Mod,ModOpts}|Emake],Opts,Files,Already) ->
    case expand(Mod,Already) of
	[] -> 
	    transform(Emake,Opts,Files,Already);
	Mods -> 
	    transform(Emake,Opts,[{Mods,ModOpts++Opts}|Files],Mods++Already)
    end;
transform([Mod|Emake],Opts,Files,Already) ->
    case expand(Mod,Already) of
	[] -> 
	    transform(Emake,Opts,Files,Already);
	Mods ->
	    transform(Emake,Opts,[{Mods,Opts}|Files],Mods++Already)
    end;
transform([],_Opts,Files,_Already) ->
    lists:reverse(Files).

expand(Mod,Already) when is_atom(Mod) ->
    expand(atom_to_list(Mod),Already);
expand(Mods,Already) when is_list(Mods), not is_integer(hd(Mods)) ->
    lists:concat([expand(Mod,Already) || Mod <- Mods]);
expand(Mod,Already) ->
    case lists:member($*,Mod) of
	true -> 
	    Fun = fun(F,Acc) -> 
			  M = filename:rootname(F),
			  case lists:member(M,Already) of
			      true -> Acc;
			      false -> [M|Acc]
			  end
		  end,
	    lists:foldl(Fun, [], filelib:wildcard(Mod++".erl"));
	false ->
	    Mod2 = filename:rootname(Mod, ".erl"),
	    case lists:member(Mod2,Already) of
		true -> [];
		false -> [Mod2]
	    end
    end.

%%% Reads the given Emakefile to see if there are any specific compile 
%%% options given for the modules.
get_opts_from_emakefile(Mods,Emakefile,Opts) ->
    case file:consult(Emakefile) of
	{ok,Emake} ->
	    Modsandopts = transform(Emake,Opts,[],[]),
	    ModStrings = [coerce_2_list(M) || M <- Mods],
	    get_opts_from_emakefile2(Modsandopts,ModStrings,Opts,[]); 
	{error,enoent} ->
	    [{Mods, Opts}];
	{error,Other} ->
	    io:format("make: Trouble reading 'Emakefile':~n~p~n",[Other]),
	    error
    end.

get_opts_from_emakefile2([{MakefileMods,O}|Rest],Mods,Opts,Result) ->
    case members(Mods,MakefileMods,[],Mods) of
	{[],_} -> 
	    get_opts_from_emakefile2(Rest,Mods,Opts,Result);
	{I,RestOfMods} ->
	    get_opts_from_emakefile2(Rest,RestOfMods,Opts,[{I,O}|Result])
    end;
get_opts_from_emakefile2([],[],_Opts,Result) ->
    Result;
get_opts_from_emakefile2([],RestOfMods,Opts,Result) ->
    [{RestOfMods,Opts}|Result].
    
members([H|T],MakefileMods,I,Rest) ->
    case lists:member(H,MakefileMods) of
	true ->
	    members(T,MakefileMods,[H|I],lists:delete(H,Rest));
	false ->
	    members(T,MakefileMods,I,Rest)
    end;
members([],_MakefileMods,I,Rest) ->
    {I,Rest}.


%% Any flags that are not recognixed as make flags are passed directly
%% to the compiler.
%% So for example make:all([load,debug_info]) will make everything
%% with the debug_info flag and load it.
load_opt(Opts) ->
    case lists:member(netload,Opts) of
	true -> 
	    netload;
	false ->
	    case lists:member(load,Opts) of
		true ->
		    load;
		_ ->
		    noload
	    end
    end.

%% 处理
process([{[], _Opts}|Rest], Worker, NoExec, Load) ->
    process(Rest, Worker, NoExec, Load);
process([{L, Opts}|Rest], Worker, NoExec, Load) ->
    Len = length(L),
    Worker2 = erlang:min(Len, Worker),
    case catch do_worker(L, Opts, NoExec, Load, Worker2) of
        error ->
            error;
        ok ->
            process(Rest, Worker, NoExec, Load)
    end;
process([], _Worker, _NoExec, _Load) ->
    up_to_date.

%% worker进行编译
do_worker(L, Opts, NoExec, Load, Worker) ->
    WorkerList = do_split_list(L, Worker),
    %io:format("worker:~p worker list(~p)~n", [Worker, length(WorkerList)]),
    % 启动进程
    Ref = make_ref(),
    PIDs =
    [begin
        start_worker(E, Opts, NoExec, Load, self(), Ref)
    end || E <- WorkerList],
    do_wait_worker(length(PIDs), Ref).

%% 等待结果
do_wait_worker(0, _Ref) ->
    ok;
do_wait_worker(N, Ref) ->
    receive
        {ack, Ref} ->
            do_wait_worker(N - 1, Ref);
        {error, Ref} ->
            throw(error);
        {'EXIT', _P, _Reason} ->
            do_wait_worker(N, Ref);
        _Other ->
            io:format("receive unknown msg:~p~n", [_Other]),
            do_wait_worker(N, Ref)
    end.

%% 将L分割成最多包含N个子列表的列表
do_split_list(L, N) ->
    Len = length(L), 
    % 每个列表的元素数
    LLen = (Len + N - 1) div N,
    do_split_list(L, LLen, []).

do_split_list([], _N, Acc) ->
    lists:reverse(Acc);
do_split_list(L, N, Acc) ->
    {L2, L3} = lists:split(erlang:min(length(L), N), L),
    do_split_list(L3, N, [L2 | Acc]).

%% 启动worker进程
start_worker(L, Opts, NoExec, Load, Parent, Ref) ->
    Fun = 
    fun() ->
        [begin 
            case recompilep(coerce_2_list(F), NoExec, Load, Opts) of
                error ->
                    Parent ! {error, Ref},
                    exit(error);
                _ ->
                    ok
            end
        end || F <- L],
        Parent ! {ack, Ref}
    end,
    spawn_link(Fun).

recompilep(File, NoExec, Load, Opts) ->
    ObjName = lists:append(filename:basename(File),
			   code:objfile_extension()),
    ObjFile = case lists:keysearch(outdir,1,Opts) of
		  {value,{outdir,OutDir}} ->
		      filename:join(coerce_2_list(OutDir),ObjName);
		  false ->
		      ObjName
	      end,
    case exists(ObjFile) of
	true ->
	    recompilep1(File, NoExec, Load, Opts, ObjFile),
            TmpName = erlang:list_to_atom(erlang:hd(string:tokens(filename:basename(ObjFile), "."))),
            io:format("CheckedOK: ~p ~n", [TmpName]);
	false ->
	    recompile(File, NoExec, Load, Opts)
    end.
 
recompilep1(File, NoExec, Load, Opts, ObjFile) ->
    Te = get_file_mtime(lists:append(File, ".erl")),
    To = get_file_mtime(ObjFile),
	 recompilep1(Te, To, File, NoExec, Load, Opts).

recompilep1(Te, To, File, NoExec, Load, Opts) when Te>To ->
    recompile(File, NoExec, Load, Opts);
recompilep1(_Erl, To, File, NoExec, Load, Opts) ->
    recompile2(To, File, NoExec, Load, Opts).

%% recompile2(ObjMTime, File, NoExec, Load, Opts)
%% Check if file is of a later date than include files.
recompile2(ObjMTime, File, NoExec, Load, Opts) ->
    IncludePath = include_opt(Opts),
    case check_includes(lists:append(File, ".erl"), IncludePath, ObjMTime) of
	true ->
	    recompile(File, NoExec, Load, Opts);
	false ->
	    false
    end.

include_opt([{i,Path}|Rest]) ->
    [Path|include_opt(Rest)];
include_opt([_First|Rest]) ->
    include_opt(Rest);
include_opt([]) ->
    [].

%% recompile(File, NoExec, Load, Opts)
%% Actually recompile and load the file, depending on the flags.
%% Where load can be netload | load | noload

recompile(File, true, _Load, _Opts) ->
    io:format("Out of date: ~s\n",[File]);
recompile(File, false, noload, Opts) ->
    io:format("Recompile: ~s\n",[File]),
    compile:file(File, [report_errors, report_warnings, error_summary |Opts]);
recompile(File, false, load, Opts) ->
    io:format("Recompile: ~s\n",[File]),
    c:c(File, Opts);
recompile(File, false, netload, Opts) ->
    io:format("Recompile: ~s\n",[File]),
    c:nc(File, Opts).

exists(File) ->
    case file:read_file_info(File) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.

coerce_2_list(X) when is_atom(X) ->
    atom_to_list(X);
coerce_2_list(X) ->
    X.

%%% If you an include file is found with a modification
%%% time larger than the modification time of the object
%%% file, return true. Otherwise return false.
check_includes(File, IncludePath, ObjMTime) ->
    Path = [filename:dirname(File)|IncludePath], 
    case epp:open(File, Path, []) of
	{ok, Epp} ->
	    check_includes2(Epp, File, ObjMTime);
	_Error ->
	    false
    end.
    
check_includes2(Epp, File, ObjMTime) ->
    case epp:parse_erl_form(Epp) of
	{ok, {attribute, 1, file, {File, 1}}} ->
	    check_includes2(Epp, File, ObjMTime);
	{ok, {attribute, 1, file, {IncFile, 1}}} ->
            case get_file_mtime(IncFile) > ObjMTime of
                true ->
		    epp:close(Epp),
		    true;
		_ ->
		    check_includes2(Epp, File, ObjMTime)
	    end;
	{ok, _} ->
	    check_includes2(Epp, File, ObjMTime);
	{eof, _} ->
	    epp:close(Epp),
	    false;
	{error, _Error} ->
	    check_includes2(Epp, File, ObjMTime)
    end.

init() ->
    ets:new(ets_file_info_tmp, [named_table, set, public]).
get_file_mtime(File) ->
    case ets:lookup(ets_file_info_tmp, File) of
        [] ->
            case file:read_file_info(File) of                
		{ok, #file_info{mtime=MTime}}  ->
                    ets:insert(ets_file_info_tmp, {File, MTime}),
		    MTime;
                _ ->
                    erlang:throw({file_not_found, File})
            end;
        [{File, MTime}] ->
            MTime
    end.

	
%%--------------------
