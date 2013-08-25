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

-type oid()      :: [any()].
-type mode()     :: read | write.
-type where()    :: [node()].
-type req()      :: any | all | majority.
-type locktype() :: direct | indirect.
-type tid()      :: any().

-type obj()      :: {oid(), mode()}
		  | {oid(), mode()}
		  | {oid(), mode(), where()}
		  | {oid(), mode(), where(), req()}.
-type objs()     :: [obj()].

-record(entry, {
	  agent         :: pid(),
	  version = 0   :: integer(),
	  type = direct :: locktype()
	 }).

-record(w, {
	  entry   :: #entry{}
	 }).

-record(r, {
	  entries = []     :: [#entry{}]
	 }).

-record(lock, {
	  object       :: oid(),
	  version = 1  :: integer(),
	  pid = self() :: pid(),
	  queue = []   :: [#entry{}]}).

-record(lock_info, {
	  lock,
	  where = node(),
	  note = []}).

-define(LOCKER, locks_server).

