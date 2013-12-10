-module(pomelo).

%% -export([]).
-compile(export_all).

-define(HANDSHAKE, 1).
-define(HANDSHAKE_ACK, 2).
-define(HEARTBEAT, 3).
-define(DATA, 4).
-define(KICKED, 5).
-define(REQUEST_START_ID, 6).

-define(REQUEST, 0).
-define(NOTIFY, 1).
-define(RESPONSE, 2).
-define(PUSH, 3).

-define(MSG_COMPRESS_ROUTE_MASK, 1).
-define(MSG_TYPE_MASK, 7).

-define(CODE_OK, 200).

-record(pomelo_opts, {host, port, socket, pid, rid, routes, rest = undefine}).

%% ====================================================================
%% API functions
%% ====================================================================

init(Host, Port, Robot_Pid, Server_Type) ->
%% 	io:format("[~p] pomelo start on Host: ~p, Port: ~p, Robot Pid: ~p ~n", [self(), Host, Port, Robot_Pid]),
	case gen_tcp:connect(Host, Port, [binary, {packet, 0}, {active, true}]) of
		{ok, Socket} ->
			Rid = ?HANDSHAKE,
			Routes = dict:store(Rid, Server_Type, dict:new()),
			Opts = #pomelo_opts{host = Host, port = Port, socket = Socket, pid = Robot_Pid, rid = ?REQUEST_START_ID, routes = Routes},
			Pid = spawn(pomelo, loop, [Opts]),
			case gen_tcp:controlling_process(Socket, Pid) of
				ok ->
%% 					io:format("[~p] pomelo connect success: ~p socket: ~p ~n", [self(), Pid, Socket]),
					ok = send_handshake(Opts),
					{ok, Pid};
				{error, Reason} ->
					io:format("[~p] bind: ~p error: ~p ~n", [self(), Pid, Reason]),
					{error, Reason}
			end;
		{error, Reason} ->
			io:format("[~p] pomelo connect error: ~p ~n", [self(), Reason]),
			{error, Reason}
	end.

%% ====================================================================
%% Internal functions
%% ====================================================================

loop(Opts) ->
%% 	io:format("[~p] socket receiving ... ~n", [self()]),
	receive
		{send, Socket, Bin} ->
			ok = gen_tcp:send(Socket, list_to_binary(Bin)),
%% 			inet:setopts(Socket, [{active, once}]),
			loop(Opts);
		{request, Route, Msg, Delay} ->
			{ok, Bin, New_Opts} = message_encode(?REQUEST, Route, Msg, Opts),
			ok = send_data(self(), Opts#pomelo_opts.socket, Bin, Delay),
			loop(New_Opts);
		{request, Route, Msg} ->
			{ok, Bin, New_Opts} = message_encode(?REQUEST, Route, Msg, Opts),
			ok = send_data(Opts#pomelo_opts.socket, Bin),
			loop(New_Opts);
		{notify, Route, Msg, Delay} ->
			{ok, Bin, New_Opts} = message_encode(?REQUEST, Route, Msg, Opts),
			ok = send_data(self(), Opts#pomelo_opts.socket, Bin, Delay),
			loop(New_Opts);
		{notify, Route, Msg} ->
			{ok, Bin, New_Opts} = message_encode(?NOTIFY, Route, Msg, Opts),
			ok = send_data(Opts#pomelo_opts.socket, Bin),
			loop(New_Opts);
		{tcp, Socket, Bin} ->
			SoFar = Opts#pomelo_opts.rest,
%% 			io:format("sofar: ~p~n", [size(SoFar)]),
%% 			if size(Bin) > 1000 ->
%% 				   io:format("[~p] bin size: ~p~n", [self(), size(Bin)]);
%% 			   true -> ok
%% 			end,
			if 
				is_binary(SoFar) ->
					{ok, Rest, _, _} = package_decode(Socket, <<SoFar/binary, Bin/binary>>, Opts),
					New_Opts = Opts#pomelo_opts{rest = Rest},
					loop(New_Opts);
				true ->
					{ok, Rest, _, _} = package_decode(Socket, Bin, Opts),
					New_Opts = Opts#pomelo_opts{rest = Rest},
					loop(New_Opts)
			end;
%% 			io:format("rest: ~p~n", [Rest]),
%% 			New_Opts = Opts#pomelo_opts{rest = Rest},
%% 			inet:setopts(Opts#pomelo_opts.socket, [{active, once}]),
%% 			loop(New_Opts);
		{tcp_closed, Socket} ->
			io:format("[~p] server close ... ~p ~n", [self(), Socket]);
		{disconnect} ->
%% 			io:format("[~p] client close ... ~p ~n", [self(), Opts#pomelo_opts.socket]),
			gen_tcp:close(Opts#pomelo_opts.socket)
	after 60000 ->
			receive
				Any ->
					io:format("[~p] any rest: ~p ~n", [self(), Any]),
					gen_tcp:close(Opts#pomelo_opts.socket)
			end,
			Opts#pomelo_opts.pid ! stop
  	end.

send_data(Pid, Socket, Bin, Delay) ->
	erlang:send_after(Delay, Pid, {send, Socket, Bin}),
	ok.

send_data(Socket, Bin) ->
	gen_tcp:send(Socket, list_to_binary(Bin)).

send_handshake(Opts) ->
	Info = {obj,[{"sys",{obj,[{"type","pomelo-erlang-tcp"},
							{"version","0.0.1a"},
							{"pomelo","0.7.x"}]}}]},
	Json = rfc4627:encode_noauto(Info),
	Bin = package_encode(?HANDSHAKE, Json),
	send_data(Opts#pomelo_opts.socket, Bin).

send_handshake_ack(Socket) ->
	Bin = package_encode(?HANDSHAKE_ACK),
	send_data(Socket, Bin).

send_heartbeat(Socket) ->
	Bin = package_encode(?HEARTBEAT),
	send_data(Socket, Bin).

package_encode(Type, Body) ->
	Len = length(Body),
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
%% 	io:format("pid: ~p, rest len: ~p, body len: ~p ~n", [self(), size(Rest4), Len]),
	if
		size(Rest4) >= Len ->
			<<Body:Len/binary, Rest5/binary>> = Rest4,
			if
				Type == ?HANDSHAKE ->
%% 					io:format("[handshake]: type ~p, len ~p, body ~p ~n", [Type, Len, Body]),
					Msg = binary_to_list(Body),
					{ok, Data, []} = rfc4627:decode_noauto(Msg),
%% 			      	io:format("[~p] msg: ~p ~n", [self(), Data]),
					{obj, [{"code", Code}, _, _]} = Data,
					if
						Code == ?CODE_OK ->
							ok = send_handshake_ack(Socket),
%% 							io:format("[~p] robot current pid: ~p ~n", [self(), Opts#pomelo_opts.pid]),
							Route = dict:fetch(?HANDSHAKE, Opts#pomelo_opts.routes),
							Opts#pomelo_opts.pid ! {handshake, Route, Msg}
					end;
				Type == ?HANDSHAKE_ACK ->
					io:format("receive handshake ack ... ~n");
				Type == ?HEARTBEAT ->
%% 					io:format("receive heartbeat ... ~n"),
					ok = send_heartbeat(Socket);
				Type == ?DATA ->
%% 					io:format("receive data ... ~p ~n", [Body]),
					{Msg_Id, _, Msg_Route, Msg_Body} = message_decode(Body),
%% 					io:format("id: ~p, type: ~p, route: ~p, body: ~p ~n", [Msg_Id, Msg_Type, Msg_Route, Msg_Body]),
					if 
						Msg_Id > 0 ->
							Route = dict:fetch(Msg_Id, Opts#pomelo_opts.routes),
							Opts#pomelo_opts.pid ! {response, Route, rfc4627:decode_noauto(Msg_Body)};
						true ->
							Opts#pomelo_opts.pid ! {on, Msg_Route, rfc4627:decode_noauto(Msg_Body)}
%% 							case dict:find(Msg_Route, Opts#pomelo_opts.routes) of
%% 								{ok, Route} ->
%% 									Opts#pomelo_opts.pid ! {on, Route, rfc4627:decode_noauto(Msg_Body)};
%% 								error ->
%% 									error
%% %% 									io:format("no find callback: ~p~n", [Msg_Route])
%% 							end
					end;
				Type == ?KICKED ->
					io:format("receive kicked ... ~n")
			end,
%% 			io:format("rest ... ~p ~n", [Rest5]),
			package_decode(Socket, Rest5, Opts);
		true ->
%% 			io:format("type ~p, l1 ~p, l2 ~p, l3 ~p, l4 ~p, l5 ~p ~n", [Type, Len1, Len2, Len3, size(Bin), Len]),
			{ok, Bin, Socket, Opts}
	end;
package_decode(Socket, Bin, Opts) ->
%% 	io:format("last bin size: ~p ~n", [size(Bin)]),
	{ok, Bin, Socket, Opts}.

message_encode(Type, Route, Msg, Opts) when Type =:= ?REQUEST -> 
	Json = rfc4627:encode_noauto(Msg),
	Rid = Opts#pomelo_opts.rid,
	Routes = dict:store(Rid, Route, Opts#pomelo_opts.routes),
	New_Opts = Opts#pomelo_opts{rid = Rid + 1, routes = Routes},
	Param1 = Type bsl 1 bor 0,
	Param2 = write_message_id(Rid),
	Param3 = length(Route),
	Data = write_byte(Param2 ++ write_byte(Route ++ Json, Param3), Param1),
%% 	io:format("send data ~p ~n", [Data]),
	Bin = package_encode(?DATA, Data),
%% 	io:format("[~p] pid: ~p ~n", [self(), New_Opts#pomelo_opts.pid]),
	{ok, Bin, New_Opts};
message_encode(Type, Route, Msg, Opts) when Type =:= ?NOTIFY -> 
	Json = rfc4627:encode_noauto(Msg),
	Param1 = Type bsl 1 bor 0,
	Param2 = length(Route),
	Data = write_byte(write_byte(Route ++ Json, Param2), Param1),
	Bin = package_encode(?DATA, Data),
	{ok, Bin, Opts}.

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

%% 写入一个字节
write_byte(Acc, Byte) -> 
    [<<Byte:8>>|Acc].

%% 读取一个字节
read_byte(Bin) ->
	<<Byte:8, Rest/binary>> = Bin,
	{Byte, Rest}.

%% 读取字符串
read_string(Len, Bin) ->
	<<String:Len/binary-unit:8, Rest/binary>> = Bin,
	{binary_to_list(String), Rest}. 