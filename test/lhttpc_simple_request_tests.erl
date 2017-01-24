-module(lhttpc_simple_request_tests).

-export([test_no/2]).
-export([request/3]).
-export([request/5]).
-import(webserver, [start/2]).

-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_STRING, "Great success!").
test_no(N, Tests) ->
    setelement(2, Tests,
        setelement(4, element(2, Tests),
            lists:nth(N, element(4, element(2, Tests))))).

%%% Eunit setup stuff

start_app() ->
  lhttpc_tests:start_app().

stop_app(_Any) ->
  lhttpc_tests:stop_app(_Any).

tcp_test_() ->
    {inorder,
        {setup, fun start_app/0, fun stop_app/1, [
                ?_test(simple_get()),
                ?_test(empty_get()),
                ?_test(get_no_content()),
                ?_test(post_no_content()),
                ?_test(get_with_mandatory_hdrs()),
                ?_test(get_with_connect_options()),
                ?_test(no_content_length()),
                ?_test(no_content_length_1_0()),
                ?_test(get_not_modified()),
                ?_test(simple_head()),
                ?_test(simple_head_atom()),
                ?_test(delete_no_content()),
                ?_test(delete_content()),
                ?_test(options_content()),
                ?_test(options_no_content()),
                ?_test(server_connection_close()),
                ?_test(client_connection_close()),
                ?_test(pre_1_1_server_connection()),
                ?_test(pre_1_1_server_keep_alive()),
                ?_test(simple_put()),
                ?_test(post()),
                ?_test(post_100_continue()),
                ?_test(bad_url()),
                ?_test(persistent_connection()),
                ?_test(connection_timeout()),
                ?_test(chunked_encoding()),
                ?_test(close_connection()),
                ?_test(message_queue())
            ]}
    }.

ssl_test_() ->
    {inorder,
        {setup, fun start_app/0, fun stop_app/1, [
                ?_test(ssl_get()),
                ?_test(ssl_post()),
                ?_test(ssl_chunked())
            ]}
    }.

other_test_() ->
    [
        ?_test(invalid_options())
    ].

request(URL, Method, Hdrs) ->
    {Host, Port, Path, Ssl} = lhttpc_lib:parse_url(URL),
    lhttpc:simple_request(Host, Port, Ssl, Path, Method, Hdrs, [], []).

request(URL, Method, Hdrs, Body, Options) ->
    {Host, Port, Path, Ssl} = lhttpc_lib:parse_url(URL),
    lhttpc:simple_request(Host, Port, Ssl, Path, Method, Hdrs, Body, Options).

%%% Tests

message_queue() ->
    receive X -> erlang:error({unexpected_message, X}) after 0 -> ok end.

simple_get() ->
    simple(get),
    simple("GET").

empty_get() ->
    Port = start(gen_tcp, [fun empty_body/5]),
    URL = url(Port, "/empty_get"),
    {ok, Response} = ?MODULE:request(URL, "GET", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

get_no_content() ->
    no_content(get, 2).

post_no_content() ->
    no_content("POST", 3).

get_with_mandatory_hdrs() ->
    Port = start(gen_tcp, [fun simple_response/5]),
    URL = url(Port, "/get_with_mandatory_hdrs"),
    Body = <<?DEFAULT_STRING>>,
    Hdrs = [
        {"content-length", integer_to_list(size(Body))},
        {"host", "localhost"}
    ],
    {ok, Response} = ?MODULE:request(URL, "POST", Hdrs, Body, []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

get_with_connect_options() ->
    Port = start(gen_tcp, [fun empty_body/5]),
    URL = url(Port, "/get_with_connect_options"),
    Options = [{connect_options, [{ip, {127, 0, 0, 1}}, {port, 0}]}],
    {ok, Response} = ?MODULE:request(URL, "GET", [], [], Options),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

no_content_length() ->
    Port = start(gen_tcp, [fun no_content_length/5]),
    URL = url(Port, "/no_content_length"),
    {ok, Response} = ?MODULE:request(URL, "GET", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

no_content_length_1_0() ->
    Port = start(gen_tcp, [fun no_content_length_1_0/5]),
    URL = url(Port, "/no_content_length_1_0"),
    {ok, Response} = ?MODULE:request(URL, "GET", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

get_not_modified() ->
    Port = start(gen_tcp, [fun not_modified_response/5]),
    URL = url(Port, "/get_not_modified"),
    {ok, Response} = ?MODULE:request(URL, "GET", [], [], []),
    ?assertEqual({304, "Not Modified"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

simple_head() ->
    Port = start(gen_tcp, [fun head_response/5]),
    URL = url(Port, "/simple_head"),
    {ok, Response} = ?MODULE:request(URL, "HEAD", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

simple_head_atom() ->
    Port = start(gen_tcp, [fun head_response/5]),
    URL = url(Port, "/simple_head_atom"),
    {ok, Response} = ?MODULE:request(URL, head, []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

delete_no_content() ->
    Port = start(gen_tcp, [fun no_content_response/5]),
    URL = url(Port, "/delete_no_content"),
    {ok, Response} = ?MODULE:request(URL, delete, []),
    ?assertEqual({204, "OK"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

delete_content() ->
    Port = start(gen_tcp, [fun simple_response/5]),
    URL = url(Port, "/delete_content"),
    {ok, Response} = ?MODULE:request(URL, "DELETE", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

options_no_content() ->
    Port = start(gen_tcp, [fun head_response/5]),
    URL = url(Port, "/options_no_content"),
    {ok, Response} = ?MODULE:request(URL, "OPTIONS", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<>>, body(Response)).

options_content() ->
    Port = start(gen_tcp, [fun simple_response/5]),
    URL = url(Port, "/options_content"),
    {ok, Response} = ?MODULE:request(URL, "OPTIONS", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

server_connection_close() ->
    Port = start(gen_tcp, [fun respond_and_close/5]),
    URL = url(Port, "/server_connection_close"),
    Body = pid_to_list(self()),
    {ok, Response} = ?MODULE:request(URL, "PUT", [], Body, []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)),
    receive closed -> ok end.

client_connection_close() ->
    Port = start(gen_tcp, [fun respond_and_wait/5]),
    URL = url(Port, "/client_connection_close"),
    Body = pid_to_list(self()),
    Hdrs = [{"Connection", "close"}],
    {ok, _} = ?MODULE:request(URL, put, Hdrs, Body, []),
    % Wait for the server to see that socket has been closed
    receive closed -> ok end.

pre_1_1_server_connection() ->
    Port = start(gen_tcp, [fun pre_1_1_server/5]),
    URL = url(Port, "/pre_1_1_server_connection"),
    Body = pid_to_list(self()),
    {ok, _} = ?MODULE:request(URL, put, [], Body, []),
    % Wait for the server to see that socket has been closed.
    % The socket should be closed by us since the server responded with a
    % 1.0 version, and not the Connection: keep-alive header.
    receive closed -> ok end.

pre_1_1_server_keep_alive() ->
    Port = start(gen_tcp, [
            fun pre_1_1_server_keep_alive/5,
            fun pre_1_1_server/5
        ]),
    URL = url(Port, "/pre_1_1_server_keep_alive"),
    Body = pid_to_list(self()),
    {ok, Response1} = ?MODULE:request(URL, get, [], [], []),
    {ok, Response2} = ?MODULE:request(URL, put, [], Body, []),
    ?assertEqual({200, "OK"}, status(Response1)),
    ?assertEqual({200, "OK"}, status(Response2)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response1)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response2)),
    % Wait for the server to see that socket has been closed.
    % The socket should be closed by us since the server responded with a
    % 1.0 version, and not the Connection: keep-alive header.
    receive closed -> ok end.

simple_put() ->
    simple(put),
    simple("PUT").

post() ->
    Port = start(gen_tcp, [fun copy_body/5]),
    URL = url(Port, "/post"),
    {X, Y, Z} = os:timestamp(),
    Body = [
        "This is a rather simple post :)",
        integer_to_list(X),
        integer_to_list(Y),
        integer_to_list(Z)
    ],
    {ok, Response} = ?MODULE:request(URL, "POST", [], Body, []),
    {StatusCode, ReasonPhrase} = status(Response),
    ?assertEqual(200, StatusCode),
    ?assertEqual("OK", ReasonPhrase),
    ?assertEqual(iolist_to_binary(Body), body(Response)).

post_100_continue() ->
    Port = start(gen_tcp, [fun copy_body_100_continue/5]),
    URL = url(Port, "/post_100_continue"),
    {X, Y, Z} = os:timestamp(),
    Body = [
        "This is a rather simple post :)",
        integer_to_list(X),
        integer_to_list(Y),
        integer_to_list(Z)
    ],
    {ok, Response} = ?MODULE:request(URL, "POST", [], Body, []),
    {StatusCode, ReasonPhrase} = status(Response),
    ?assertEqual(200, StatusCode),
    ?assertEqual("OK", ReasonPhrase),
    ?assertEqual(iolist_to_binary(Body), body(Response)).

bad_url() ->
    ?assertError(_, ?MODULE:request(ost, "GET", [])).

persistent_connection() ->
    Port = start(gen_tcp, [
            fun simple_response/5,
            fun simple_response/5,
            fun copy_body/5
        ]),
    URL = url(Port, "/persistent_connection"),
    {ok, FirstResponse} = ?MODULE:request(URL, "GET", []),
    Headers = [{"KeepAlive", "300"}], % shouldn't be needed
    {ok, SecondResponse} = ?MODULE:request(URL, "GET", Headers),
    {ok, ThirdResponse} = ?MODULE:request(URL, "POST", []),
    ?assertEqual({200, "OK"}, status(FirstResponse)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(FirstResponse)),
    ?assertEqual({200, "OK"}, status(SecondResponse)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(SecondResponse)),
    ?assertEqual({200, "OK"}, status(ThirdResponse)),
    ?assertEqual(<<>>, body(ThirdResponse)).

connection_timeout() ->
    Port = start(gen_tcp, [fun simple_response/5, fun simple_response/5]),
    URL = url(Port, "/connection_timeout"),
    {ok, Response} = ?MODULE:request(URL, get, [], [], [ {connection_timeout, 50} ]),
    ?assertEqual({0,1}, lhttpc_lb:connection_count("localhost", Port, false)),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)),
    timer:sleep(100),
    ?assertEqual({0,0}, lhttpc_lb:connection_count("localhost", Port, false)).

chunked_encoding() ->
    Port = start(gen_tcp, [fun chunked_response/5, fun chunked_response_t/5]),
    URL = url(Port, "/chunked_encoding"),
    {ok, FirstResponse} = ?MODULE:request(URL, get, []),
    ?assertEqual({200, "OK"}, status(FirstResponse)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(FirstResponse)),
    ?assertEqual("chunked", lhttpc_lib:header_value("transfer-encoding",
            headers(FirstResponse))),
    {ok, SecondResponse} = ?MODULE:request(URL, get, []),
    ?assertEqual({200, "OK"}, status(SecondResponse)),
    ?assertEqual(<<"Again, great success!">>, body(SecondResponse)),
    ?assertEqual("ChUnKeD", lhttpc_lib:header_value("transfer-encoding",
            headers(SecondResponse))),
    ?assertEqual("1", lhttpc_lib:header_value("trailer-1",
            headers(SecondResponse))),
    ?assertEqual("2", lhttpc_lib:header_value("trailer-2",
            headers(SecondResponse))).

close_connection() ->
    %receive _ -> ok after 0 -> ok end,
    Port = start(gen_tcp, [fun close_connection/5]),
    URL = url(Port, "/close"),
    ?assertEqual({error, connection_closed}, ?MODULE:request(URL, "GET", [])).

ssl_get() ->
    Port = start(ssl, [fun simple_response/5]),
    URL = ssl_url(Port, "/ssl_get"),
    {ok, Response} = ?MODULE:request(URL, "GET", []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

ssl_post() ->
    Port = start(ssl, [fun copy_body/5]),
    URL = ssl_url(Port, "/ssl_post"),
    Body = "SSL Test <o/",
    BinaryBody = list_to_binary(Body),
    {ok, Response} = ?MODULE:request(URL, "POST", [], Body, []),
    ?assertEqual({200, "OK"}, status(Response)),
    ?assertEqual(BinaryBody, body(Response)).

ssl_chunked() ->
    Port = start(ssl, [fun chunked_response/5, fun chunked_response_t/5]),
    URL = ssl_url(Port, "/ssl_chunked"),
    FirstResult = ?MODULE:request(URL, get, []),
    ?assertMatch({ok, _}, FirstResult),
    {ok, FirstResponse} = FirstResult,
    ?assertEqual({200, "OK"}, status(FirstResponse)),
    ?assertEqual(<<?DEFAULT_STRING>>, body(FirstResponse)),
    ?assertEqual("chunked", lhttpc_lib:header_value("transfer-encoding",
            headers(FirstResponse))),
    SecondResult = ?MODULE:request(URL, get, []),
    {ok, SecondResponse} = SecondResult,
    ?assertEqual({200, "OK"}, status(SecondResponse)),
    ?assertEqual(<<"Again, great success!">>, body(SecondResponse)),
    ?assertEqual("ChUnKeD", lhttpc_lib:header_value("transfer-encoding",
            headers(SecondResponse))),
    ?assertEqual("1", lhttpc_lib:header_value("Trailer-1",
            headers(SecondResponse))),
    ?assertEqual("2", lhttpc_lib:header_value("Trailer-2",
            headers(SecondResponse))).

invalid_options() ->
    ?assertError({bad_options, [{foo, bar}, bad_option]},
        ?MODULE:request("http://localhost/", get, [], <<>>,
            [bad_option, {foo, bar}])).

%%% Helpers functions

simple(Method) ->
    Port = start(gen_tcp, [fun simple_response/5]),
    URL = url(Port, "/simple"),
    {ok, Response} = ?MODULE:request(URL, Method, []),
    {StatusCode, ReasonPhrase} = status(Response),
    ?assertEqual(200, StatusCode),
    ?assertEqual("OK", ReasonPhrase),
    ?assertEqual(<<?DEFAULT_STRING>>, body(Response)).

no_content(Method, Count) ->
    Responses = lists:duplicate(Count, fun no_content_response/5),
    Port = start(gen_tcp, Responses),
    URL = url(Port, "/" ++ lhttpc_lib:maybe_atom_to_list(Method) ++ "_no_content"),
    lists:foreach(
      fun (_) ->
              {ok, Response} = ?MODULE:request(URL, Method, [], <<>>,
                                              [ {connect_timeout, 100},
                                                {connection_timeout, 5000},
                                                {max_connections, 3} ]),
              ?assertEqual({204, "OK"}, status(Response)),
              ?assertEqual(<<>>, body(Response)),
              timer:sleep(100)
      end, Responses).

url(Port, Path) ->
  lhttpc_tests:url(Port, Path).

ssl_url(Port, Path) ->
  lhttpc_tests:ssl_url(Port, Path).

status({Status, _, _}) ->
    Status.

body({_, _, Body}) ->
    Body.

headers({_, Headers, _}) ->
    Headers.

%%% Responders
simple_response(Module, Socket, _Request, _Headers, Body) ->
  lhttpc_tests:simple_response(Module, Socket, _Request, _Headers, Body).

head_response(Module, Socket, _Request, _Headers, _Body) ->
  lhttpc_tests:head_response(Module, Socket, _Request, _Headers, _Body).

no_content_response(Module, Socket, _Request, _Headers, _Body) ->
  lhttpc_tests:no_content_response(Module, Socket, _Request, _Headers, _Body).

empty_body(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:empty_body(Module, Socket, _A, _B, _C).

copy_body(Module, Socket, _A, _B, Body) ->
  lhttpc_tests:copy_body(Module, Socket, _A, _B, Body).

copy_body_100_continue(Module, Socket, _A, _B, Body) ->
  lhttpc_tests:copy_body_100_continue(Module, Socket, _A, _B, Body).

respond_and_close(Module, Socket, _A, _B, Body) ->
  lhttpc_tests:respond_and_close(Module, Socket, _A, _B, Body).

respond_and_wait(Module, Socket, _A, _B, Body) ->
  lhttpc_tests:respond_and_wait(Module, Socket, _A, _B, Body).

pre_1_1_server(Module, Socket, _A, _B, Body) ->
  lhttpc_tests:pre_1_1_server(Module, Socket, _A, _B, Body).

pre_1_1_server_keep_alive(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:pre_1_1_server_keep_alive(Module, Socket, _A, _B, _C).

no_content_length(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:no_content_length(Module, Socket, _A, _B, _C).

no_content_length_1_0(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:no_content_length_1_0(Module, Socket, _A, _B, _C).

chunked_response(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:chunked_response(Module, Socket, _A, _B, _C).

chunked_response_t(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:chunked_response_t(Module, Socket, _A, _B, _C).

close_connection(Module, Socket, _A, _B, _C) ->
  lhttpc_tests:close_connection(Module, Socket, _A, _B, _C).

not_modified_response(Module, Socket, _Request, _Headers, _Body) ->
  lhttpc_tests:not_modified_response(Module, Socket, _Request, _Headers, _Body).

