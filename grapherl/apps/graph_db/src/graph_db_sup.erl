%%%-------------------------------------------------------------------
%% @doc graph_db top level supervisor.
%% @end
%%%-------------------------------------------------------------------
 
-module(graph_db_sup).
-author('kansi13@gmail.com').

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("apps/grapherl/include/grapherl.hrl").

-define(SERVER, ?MODULE).

-define(SIMPLE_CHILD(WorkerMod), ?CHILD(WorkerMod, WorkerMod, [], transient, worker)).

-define(MANAGER_CHILD(WorkerMod, Args), ?CHILD(WorkerMod, WorkerMod, Args, transient, worker)).

-define(SIMPLE_SUP(SupId, WorkerMod),
        ?CHILD(SupId, simple_sup,
               [SupId, simple_one_for_one, [?SIMPLE_CHILD(WorkerMod)]], permanent,
               supervisor )).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Process hirerarcy description 
%%====================================================================
%% router_worker : processes that handle the open UDP socket and receive  metric.
%% router_manager: gen_server process to (dynamicaly) spawn new graph_db_router
%% process. Also stores data regarding open UDP socket is case there are more
%% than one receiving sockets open.
%% 
%% graph_data_server: server that receives requests for gathering data. It
%% spawns a graph_db_aggregator process and starts listening for any new
%% requests.
%% 
%% graph_db_manager: stores meta data regarding ets cache and correspoding
%% database for different metrics, this data is stored in ETS table so that it
%% can be read concurrently by graph_db_worker processes so as correctly store
%% the data point in the table. It also stores user configration data eg.
%% TIME_INTERVAL after which cache should be dumped into database. It is
%% further resposible to implement these user configrations eg. dumping the
%% database after timeout.
%%
%% graph_db_worker: is a gen_server that caches and stores data into database.
%% User defines modules which should be used for caching and storing data,
%% default being mod_ETS and mod_levelDB. Both these modules are based on
%% gen_db behaviour module that defines necessary callbacks to implement
%% database modules.
%% 
%% We use poolboy lib to manage and perform action using graph_db_worker as the
%% worker process.
%% NOTE: dumping cache should be a tanscation actions during which no further
%% data is allowed to enter into cache. In order to achieve this we mark the
%% state (which would be stored in and ETS table) of cache db as unavailable
%% during the transaction. If any worker is in process of storing data into
%% cache we wait for it to terminate. 
%% NOTE: The ets table for storing state of cache table will have
%% {write_concurrency, false} which will prevent any process from reading the
%% state while it is being changed.
%%
%%                                                  +----------------+
%%                                                  | graph_db_sup   |
%%                                                  +--------+-------+
%%                                                           | (one_for_one)
%%                            +------------------------------+-------------------------------+
%%                            |                                                              |
%%                    +-------+----------+                                           +-------+-----+
%%                    |    ?DB_SUP       |                                           | ?ROUTER_SUP |
%%                    +------------------+                                           +-------+-----+
%%                            | (one_for_one)                                                | (one_for_all)            
%%              +-------------+------------+                                   +-------------+------------+             
%%              |                          |                                   |                          |             
%%   +----------+--------+         +-------+-----------+            +----------+-----------+      +-------+-----------+ 
%%   | graph_data_server |         | graph_db_manager  |            |   router_manager     |      | ?ROUTER_WORKER_SUP| 
%%   +-------------------+         +-------+-----------+            +----------------------+      +-------+-----------+ 
%%                                                                                                        |(simple_one_for_one)
%%                                                                                                  +-----|----------+  
%%                                                                                                +-------|---------+|  
%%                                                                                               +--------+--------+|+  
%%                                                                                               | graph_db_router |+   
%%                                                                                               +-----------------+    

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    %% Initializations
    ok = application:ensure_started(lager),
    ok = application:ensure_started(poolboy),
    %% router for handling incoming metric data points
    RouterSupSpec =[?MANAGER_CHILD(router_manager, []),
                    ?SIMPLE_SUP(?ROUTER_WORKER_SUP, router_worker)],

    %% poolboy initalization for db worker processes
    {ok, DbMod}       = application:get_env(graph_db, db_mod),
    {ok, CacheMod}    = application:get_env(graph_db, cache_mod),
    {ok, Size}        = application:get_env(graph_db, num_db_workers),

    ?INFO("Evironment starting ~p ~p ~p.~n", [DbMod, CacheMod, Size]),

    PoolArgs          = [{name, {local, ?DB_POOL}}, {worker_module, db_worker},
                         {size, Size}, {max_overflow, Size*2}],
    DbWorkerSpecs     = poolboy:child_spec(?DB_POOL, PoolArgs,
                                           [{db_mod, DbMod },
                                            {cache_mod, CacheMod}]),

    DataServerSpec    = ?MANAGER_CHILD(db_manager, [[{db_mod, DbMod}, {cache_mod, CacheMod}]]),
    DbManagerSpec     = ?MANAGER_CHILD(graph_db_server, []),
    DbSupSpec         = [DbManagerSpec,DataServerSpec],

    %% TODO get database module from application environment.
    ChildSpecs = [
                  ?CHILD(?ROUTER_SUP, simple_sup, [?ROUTER_SUP, one_for_all, RouterSupSpec], permanent, supervisor)
                 ,?CHILD(?DB_SUP, simple_sup, [?DB_SUP, one_for_one, DbSupSpec], permanent, supervisor)
                 ,DbWorkerSpecs
                 ],

    ?INFO("~p starting.~n", [?SERVER]),
    {ok, { {one_for_all, 500, 60}, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================
