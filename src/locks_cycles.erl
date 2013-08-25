%% -*- mode: erlang; indent-tabs-mode: nil; -*-
%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%
%% Copyright (C) 2013 Ulf Wiger. All rights reserved.
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%%---- END COPYRIGHT ---------------------------------------------------------
%% Key contributor: Thomas Arts <thomas.arts@quviq.com>
%%
%%=============================================================================
%%
%% to compute strong components
%%
%% freely taken from Peter Hogfeldt
%%

-module(locks_cycles).

-export([components/2, ex/1]).

-import(lists, [member/2, keysearch/3, delete/2, map/2]).

%% -type components([A], fun((A, A) -> boolean())) -> [[A]].

components(Nodes,Arrow) ->
  Graph =
    map(fun(Node) ->
           {Node, [ N || N <- Nodes, Arrow(Node, N)]}
        end,Nodes),
    io:fwrite("Graph = ~p~n", [Graph]),
  [ Comp || Comp<-sc(Nodes, Graph, [], []), oncycle(Comp, Arrow)].

oncycle([A], Arrow) ->
  Arrow(A, A);
oncycle(_, _Arrow) ->
  true.


sc([],_,_,Ss) ->
  Ss;
sc([V|Vs],G,Us,Ss) ->
  case member(V,Us) of
       true ->
         sc(Vs,G,Us,Ss);
       false ->
         {U0s,_,_,S0s} = vis(V,G,[],{Us,[],[],Ss}),
         sc(Vs,G,U0s,S0s)
  end.

vis(V, G, As, {Us, Cs, Bs, Ss}) ->
  {value, {_, Adjs}} = keysearch(V, 1, G),
  {U0s, C0s, B0s, S0s} =
     vis1(Adjs, G, [V|As], {[V|Us], [V|Cs], [], Ss}),
  case intersect(B0s, As) of
       true ->
         {U0s, C0s, Bs ++ B0s, S0s};
       false ->
         {S1s, C1s} = split(V, C0s),
         {U0s, C1s, Bs ++ delete(V, B0s), [S1s|S0s]}
  end.

vis1([], _, _, Res) ->
  Res;
vis1([V|Vs], G, As, {Us, Cs, Bs, Ss}) ->
  case member(V, Us) of
       true ->
         case member(V, As) of
              true ->
                vis1(Vs, G, As, {Us, Cs, [V|Bs], Ss});
              false ->
                vis1(Vs, G, As, {Us, Cs, Bs, Ss})
         end;
       false ->
         vis1(Vs, G, As, vis(V, G, As, {Us, Cs, Bs, Ss}))
  end.

intersect([], _Bs) ->
  false;
intersect([A|As], Bs) ->
  case member(A, Bs) of
       true ->
         true;
       false ->
         intersect(As, Bs)
  end.

split(V, Cs) ->
  split(V, Cs, []).

split(_V, [], Ps) ->
  {Ps, []};
split(V, [V|Cs], Ps) ->
  {[V|Ps], Cs};
split(V, [C|Cs], Ps) ->
  split(V, Cs, [C|Ps]).


ex(1) ->
  [{dp,a,b},{dp,a,a},{dp,b,a},{dp,a,c},{dp,c,c}];
ex(2) ->
  [{dp,a,b},{dp,a,a},{dp,b,a},{dp,a,c},{dp,c,c},{dp,c,d}];
ex(3) ->
  [{1,2},{1,1},{2,2},{1,3},{3,3}];
ex(4) ->
  [{1,2,obj1},{1,3,obj2},{3,1,obj3}].
