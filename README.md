Pomelo-Erlang-TCP
================

这是一个用来支持 pomelo-hybridconnector(tcp) 的 erlang 通讯组件，底层使用的是 socket 的二进制协议，json 解析部分用的是 rfc4627

目前版本：0.0.1a

目前功能：

1. 可以实现与 pomelo 底层 socket 的二进制通讯

2. 可以支持 request 和 notify 的消息发送延迟

3. 支持服务器的心跳（heartbeat）模式

4. 非常适合做机器人压测

================

@暂不支持 pomelo 的 routeDict， 服务端的 protobuf

相关的服务器需设置如下参数：
```javascript
app.set('connectorConfig', {
  connector : pomelo.connectors.hybridconnector,
  heartbeat : 30,
  disconnectOnTimeout : true
  useDict : false,
  useProtobuf : false
});
```

How To Use
================

##1. 初始化并连接服务器

###通过 pomelo 模块的 init 方法建立连接，并根据 Server_Type 的值向 Robot_Pid 进程发送 {handshake, Server, Msg} 消息
```erlang
init(Host, Port, Robot_Pid, Server_Type) -> {ok, Pid} ｜ {error, Reason}
```

###for example:
```erlang
...
{ok, Pid} = pomelo:init("127.0.0.1", 3014, self(), "gate"),
...

loop(Opts) ->
  receive
    {handshake, Server, Msg} -> ok  %%相关逻辑处理
  end.
```


##2. Request, Notify, Disconnect

###通过初始化连接成功后返回的 pomelo pid 发送消息，可以指定消息延时的时间 (ms)

###request

###for example:
```erlang
Pid ! {request, "gate.gateHandler.entry", {obj, []}}.
Pid ! {request, "gate.gateHandler.entry", {obj, []}, 1000}.
```

###notify

###for example:
```erlang
Pid ! {notify, "connector.connectHandler.leave", {obj, []}}.
Pid ! {notify, "connector.connectHandler.leave", {obj, []}, 1000}.
```

###disconnect

###for example:
```erlang
Pid ! {disconnect}.
```


##3. Response, Push（服务器推送）

###使用 loop() 以及尾递归模式，接受来自 pomelo 进程的消息
```erlang
loop(Opts) ->
  receive
    {response, Route, Body} -> ok;  %%处理 request 时的对应 respnose 消息
    {on, Route, Body} -> ok         %%处理服务器推送（push）消息
  end.
```

###for example:
```erlang
{response, Route, Body} ->
  case Route of
    "gate.gateHandler.entry" ->
      {ok, New_Opts} = handle_gate(Body, Opts),
      loop(New_Opts);
    _ ->
      io:format("[~p] robot error route: ~p~n", [self(), Route])
  end;
{on, Route, Body} ->
  case Route of
    "onLeave" ->
      {ok, New_Opts} = event_start(Body, Opts),
      loop(New_Opts);
```
