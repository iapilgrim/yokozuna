%% -------------------------------------------------------------------
%%
%% yz_pb_search: PB Service for Yokozuna queries
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Implements a `riak_api_pb_service' for performing search
%% queries in Yokozuna.
-module(yz_pb_search).

-include_lib("riak_pb/include/riak_search_pb.hrl").
-include("yokozuna.hrl").

-behaviour(riak_api_pb_service).

-export([init/0,
         decode/2,
         encode/1,
         process/2,
         process_stream/3]).

-import(riak_pb_search_codec, [encode_search_doc/1]).

-record(state, {client}).

%% @doc init/0 callback. Returns the service internal start state.
-spec init() -> any().
init() ->
    {ok, C} = riak_search:local_client(),
    #state{client=C}.

%% @doc decode/2 callback. Decodes an incoming message.
decode(Code, Bin) ->
    {ok, riak_pb_codec:decode(Code, Bin)}.

%% @doc encode/1 callback. Encodes an outgoing response message.
encode(Message) ->
    {ok, riak_pb_codec:encode(Message)}.

%% @doc process/2 callback. Handles an incoming request message.
process(Msg, #state{client=Client}=State) ->
    #rpbsearchqueryreq{index=IndexBin, sort=_Sort0,
                       fl=_FL0, presort=_Presort0}=Msg,
    case parse_squery(Msg) of
        {ok, SQuery} ->
            Mapping = yz_events:get_mapping(),
            Index = binary_to_list(IndexBin),
            try
                {RHeaders, Body} = yz_solr:dist_search(Index,
                                                       [],
                                                       [{q, SQuery#squery.q}],
                                                       Mapping),
                Resp = #rpbsearchqueryresp{
                    docs = [encode_search_doc([{id, Body}])],
                    max_score = 0.1,
                    num_found = 1
                },
                {reply, Resp, State}
            catch
                throw:not_found ->
                    ErrMsg = io_lib:format(?YZ_ERR_INDEX_NOT_FOUND, [Index]),
                    {error, ErrMsg, State};
                throw:insufficient_vnodes_available ->
                    {error, ?YZ_ERR_NOT_ENOUGH_NODES, State}
            end;
        {error, missing_query} ->
            {error, "Missing query", State}
    end.

%% @doc process_stream/3 callback. Ignored.
process_stream(_,_,State) ->
    {ignore, State}.

%% ---------------------------------
%% Internal functions
%% ---------------------------------

parse_squery(#rpbsearchqueryreq{q = <<>>}) ->
    {error, missing_query};
parse_squery(#rpbsearchqueryreq{q=Query,
                                rows=Rows, start=Start,
                                filter=Filter,
                                df=DefaultField, op=DefaultOp}) ->
    {ok, #squery{q=Query,
                 filter=default(Filter, ""),
                 default_op=default(DefaultOp, undefined),
                 default_field=default(DefaultField,undefined),
                 query_start=default(Start, 0),
                 query_rows=default(Rows, ?DEFAULT_RESULT_SIZE)}}.

default(undefined, Default) ->
    Default;
default(Value, _) ->
    Value.
