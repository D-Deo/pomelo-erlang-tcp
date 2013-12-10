-module(pomelo).

-export([on/3, notify/3, request/4, init/3, disconnect/1, loop/1]).

-import(rfc4627, [encode/1, decode/1]).

-define(HANDSHAKE, 1).
-define(HANDSHAKE_ACK, 2).
-define(HEARTBEAT, 3).
-define(DATA, 4).
-define(KICKED, 5).

-define(REQUEST, 0).
-define(NOTIFY, 1).
-define(RESPONSE, 2).
-define(PUSH, 3).

-define(MSG_COMPRESS_ROUTE_MASK, 1).
-define(MSG_TYPE_MASK, 7).

-define(CODE_OK, 200).

-record(pomelo_opts, {host, port, pid = undefine, socket = undefine, rest = undefine, rid = 1, callbacks = dict:new(), player = undefine}).

%% ====================================================================
%% API functions
%% ====================================================================

init(Host, Port, Callback) ->
	io:format("pomelo start on Host: ~p Port: ~p ~n", [Host, Port]),
	case gen_tcp:connect(Host, Port, [binary, {packet, 0}, {active, once}]) of
		{ok, Socket} ->
			Opts = #pomelo_opts{host = Host, port = Port, socket = Socket},
			Rid = Opts#pomelo_opts.rid,
			Callbacks = dict:store(Rid, Callback, Opts#pomelo_opts.callbacks),
			New_Opts = Opts#pomelo_opts{rid = Rid + 1, callbacks = Callbacks},
			Pid = spawn(?MODULE, loop, [New_Opts]),
			case gen_tcp:controlling_process(Socket, Pid) of
				ok ->
					send_handshake(Socket);
				{error, Reason} ->
					io:format("reason ~p ~n", [Reason])
			end,
			io:format("pomelo connect success: ~p ~n", [Pid]),
			{Pid};
		{error, Reason} ->
			io:format("pomelo connect error: ~p ~n", [Reason])
	end.

request(Route, Msg, Callback, Opts) -> 
	io:format("pomelo request ... ~n"),
	Type = ?REQUEST,
	Json = rfc4627:encode_noauto(Msg),
	Rid = Opts#pomelo_opts.rid,
	Callbacks = dict:store(Rid, Callback, Opts#pomelo_opts.callbacks),
	New_Opts = Opts#pomelo_opts{rid = Rid + 1, callbacks = Callbacks},
	Param1 = Type bsl 1 bor 0,
	Param2 = write_message_id(Opts#pomelo_opts.rid),
	Param3 = length(Route),
	io:format("1: ~p, 2: ~p, 3: ~p 4: ~p 5: ~p ~n", [Param1, Param2, Param3, Route, Json]),
	Data = write_byte(Param2 ++ write_byte(Route ++ Json, Param3), Param1),
	io:format("send data ~p ~n", [Data]),
	Bin = package_encode(?DATA, Data),
	io:format("self: ~p ~n", [self()]),
%% 	erlang:send_after(2000, self(), {send, New_Opts#pomelo_opts.socket, Bin, New_Opts}),
	send_data(New_Opts#pomelo_opts.socket, Bin),
	inet:setopts(New_Opts#pomelo_opts.socket, [{active, once}]),
	loop(New_Opts).

notify(Route, Msg, Opts) -> 
	io:format("pomelo notify ... ~n"),
	Type = ?NOTIFY,
	Json = rfc4627:encode_noauto(Msg),
	Param1 = Type bsl 1 bor 0,
	Param2 = length(Route),
	io:format("1: ~p, 2: ~p, 3: ~p 4: ~p ~n", [Param1, Param2, Route, Json]),
	Data = write_byte(write_byte(Route ++ Json, Param2), Param1),
	io:format("send data ~p ~n", [Data]),
	Bin = package_encode(?DATA, Data),
	io:format("self: ~p ~n", [self()]),
%% 	erlang:send_after(2000, self(), {send, Opts#pomelo_opts.socket, Bin, Opts}),
	send_data(Opts#pomelo_opts.socket, Bin),
	inet:setopts(Opts#pomelo_opts.socket, [{active, once}]),
	loop(Opts).

on(Route, Callback, Opts) ->
	io:format("pomelo on ... ~n"),
	Callbacks = dict:store(Route, Callback, Opts#pomelo_opts.callbacks),
	Opts#pomelo_opts{callbacks = Callbacks}.

disconnect(Opts) ->
	io:format("pomelo disconnect ... ~p ~n", [Opts#pomelo_opts.socket]),
	ok = gen_tcp:close(Opts#pomelo_opts.socket).

%% ====================================================================
%% Internal functions
%% ====================================================================

loop(Opts) ->
	io:format("socket receiving ... ~n"),
	receive
		{send, Socket, Bin, Opts} ->
			send_data(Socket, Bin),
			loop(Opts);
		{tcp, Socket, Bin} ->
			SoFar = Opts#pomelo_opts.rest,
%% 			io:format("sofar: ~p~n", [size(SoFar)]),
			if size(Bin) > 1000 ->
				   io:format("bin len: ~p~n", [size(Bin)]);
			   true -> true
			end,
			if 
				is_binary(SoFar) ->
					{Rest} = package_decode(Socket, <<SoFar/binary, Bin/binary>>, Opts);
				true ->
					{Rest} = package_decode(Socket, Bin, Opts)
			end,
			io:format("rest: ~p~n", [Rest]),
			New_Opts = Opts#pomelo_opts{rest = Rest},
			inet:setopts(Opts#pomelo_opts.socket, [{active, once}]),
			loop(New_Opts);
		{tcp_closed, Socket} ->
			io:format("close ... ~p ~n", [Socket])
%% 	after 10000 ->
%% 			Size = size(Opts#pomelo_opts.rest),
%% 			if Size > 0 -> 
%% 				   {error, Bin} = gen_tcp:recv(Opts#pomelo_opts.socket, 0),
%% 				   io:format("[~p] bin size: ~p bin: ~p~n", [self(), Size, Bin]),
%% 				   loop(Opts);
%% 			   true -> loop(Opts)
%% 			end
  	end.

send_handshake(Socket) ->
	Info = {obj,[{"sys",{obj,[{"type","pomelo-flash-tcp"},
							{"version","0.1.5b"},
							{"pomelo","0.5.x"}]}}]},
	%%  io:format("data: ~p~n", [Info]),
	Json = rfc4627:encode_noauto(Info),
	%%  io:format("json: ~p  json length: ~p ~n", [Json, length(Json)]),
	Bins = package_encode(?HANDSHAKE, Json),
	%%  io:format("send hankshake ~p ~n", [Bins]),
	ok = gen_tcp:send(Socket, list_to_binary(Bins)).

send_handshake_ack(Socket) ->
	Bins = package_encode(?HANDSHAKE_ACK),
	%%  io:format("send handshake ack ~p ~n", [Bins]),
	ok = gen_tcp:send(Socket, list_to_binary(Bins)).

send_data(Socket, Bin) ->
	%%  io:format("send data ... ~n"),
	ok = gen_tcp:send(Socket, list_to_binary(Bin)).

package_encode(Type, Body) ->
	Len = length(Body),
	%%  io:format("body length: ~p ~n", [Len]),
	write_byte(
	  write_byte(
		write_byte(
		  write_byte(
			Body, 
			Len band 255), 
		  Len bsr 8 band 255), 
		Len bsr 16 band 255), 
	  Type band 255).

package_encode(Type) ->
	write_byte(write_byte(write_byte(write_byte([], 0), 0), 0), Type band 255).
	
package_decode(Socket, Bin, Opts) when size(Bin) > 4 ->
	{Type, Rest1} = read_byte(Bin),
	{Len1, Rest2} = read_byte(Rest1),
	{Len2, Rest3} = read_byte(Rest2),
	{Len3, Rest4} = read_byte(Rest3),
	Len = (Len1 bsl 16 bor Len2 bsl 8 bor Len3) bsr 0,
	io:format("pid: ~p, rest len: ~p, body len: ~p ~n", [self(), size(Rest4), Len]),
	if
		size(Rest4) >= Len ->
			<<Body:Len/binary, Rest5/binary>> = Rest4,
			if
				Type == ?HANDSHAKE ->
					io:format("[handshake]: type ~p, len ~p, body ~p ~n", [Type, Len, Body]),
					Msg = binary_to_list(Body),
					{ok, Data, []} = rfc4627:decode_noauto(Msg),
			      	io:format("msg: ~p ~n", [Data]),
					{obj, [{"code", Code}, _, _]} = Data,
					if
						Code == ?CODE_OK ->
							send_handshake_ack(Socket),
							Callback = dict:fetch(1, Opts#pomelo_opts.callbacks),
							Callback(Msg, Opts)
					end;
				Type == ?HANDSHAKE_ACK ->
					io:format("receive handshake ack ... ~n");
				Type == ?HEARTBEAT ->
					io:format("receive heartbeat ... ~n");
				Type == ?DATA ->
					io:format("receive data ... ~p ~n", [Body]),
					{Msg_Id, Msg_Type, Msg_Route, Msg_Body} = message_decode(Body),
					io:format("id: ~p, type: ~p, route: ~p, body: ~p ~n", [Msg_Id, Msg_Type, Msg_Route, Msg_Body]),
					if 
						Msg_Id > 0 ->
							Callback = dict:fetch(Msg_Id, Opts#pomelo_opts.callbacks),
							New_Opts = Opts#pomelo_opts{rest = Rest5},
							Callback(rfc4627:decode_noauto(Msg_Body), New_Opts);
						true ->
							case dict:find(Msg_Route, Opts#pomelo_opts.callbacks) of
								{ok, Callback} ->
									New_Opts = Opts#pomelo_opts{rest = Rest5},
									Callback(rfc4627:decode_noauto(Msg_Body), New_Opts);
								error ->
									io:format("no find callback: ~p~n", [Msg_Route])
							end
					end;
				Type == ?KICKED ->
					io:format("receive kicked ... ~n")
			end,
			io:format("rest ... ~p ~n", [Rest5]),
			package_decode(Socket, Rest5, Opts);
		true ->
			io:format("type ~p, l1 ~p, l2 ~p, l3 ~p, l4 ~p, l5 ~p ~n", [Type, Len1, Len2, Len3, size(Bin), Len]),
			{Bin}
	end;
package_decode(Socket, Bin, Opts) ->
	io:format("last bin size: ~p ~n", [size(Bin)]),
	{Bin}.

message_decode(Bin) ->
	{Flag, Rest} = read_byte(Bin),
%% 	Is_Compress_Route = Flag band ?MSG_COMPRESS_ROUTE_MASK,
	Type = (Flag bsr 1) band ?MSG_TYPE_MASK,
	{Id, Rest1} = read_message_id(Type, Rest),
	{Route, Rest2} = read_message_route(Type, Rest1),
	{Id, Type, Route, binary_to_list(Rest2)}.

write_message_id(Id) when Id =/= 0 ->
	List = [Id band 127],
	New_Id = Id bsr 7,
	encode_message_id(New_Id, List);
write_message_id(Id) -> [Id].

encode_message_id(Id, List) when Id > 0 ->
	New_List = [(Id band 127 bor 128)|List],
	New_Id = Id bsr 7,
	encode_message_id(New_Id, New_List);
encode_message_id(Id, List) -> List.

read_message_id(T, Bin) when (T =:= ?REQUEST) or (T =:= ?RESPONSE) -> 
	{Byte, Rest} = read_byte(Bin),
	Id = Byte band 127,
	decode_message_id(Id, Rest);
read_message_id(T, Bin) -> {0, Bin}.

decode_message_id(Id, Bin) when Bin band 128 -> 
	Temp_Id = Id bsl 7,
	{Byte, Rest} = read_byte(Bin),
	New_Id = Temp_Id bor (Byte band 127),
	decode_message_id(New_Id, Rest);
decode_message_id(Id, Bin) -> {Id, Bin}.

read_message_route(T, Bin) when (T =:= ?REQUEST) or (T =:= ?NOTIFY) or (T =:= ?PUSH) ->
	{Len, Rest} = read_byte(Bin),
	{Route, Rest1} = read_string(Len, Rest),
	{Route, Rest1};
read_message_route(T, Bin) when (T =:= ?RESPONSE) -> {"", Bin}.

has_id(Type) ->
	(Type == ?REQUEST) or (Type == ?RESPONSE).

%% 写入一个字节
write_byte(Acc, Byte) -> 
    [<<Byte:8>>|Acc].

%% 写入一个32位整数
write_int32(Acc, Int) ->
	[<<Int:32>>|Acc].

%% 写入一个字符串
write_string(Acc, Str) ->
    [list_to_binary(Str)|Acc].

%% 写入一个带有32位长度的字符串
write_string(Str) ->
    Len = binary_to_list(<<(length(Str)):32>>),
	Len ++ Str.

%% 读取一个字节
read_byte(Bin) ->
	<<Byte:8, Rest/binary>> = Bin,
	{Byte, Rest}.

%% 读取32位整数
read_int32(Bin) ->
	<<Int:32/signed, Rest/binary>> = Bin,
	{Int, Rest}.

%% 读取字符串
read_string(Len, Bin) ->
	<<String:Len/binary-unit:8, Rest/binary>> = Bin,
	{binary_to_list(String), Rest}.
