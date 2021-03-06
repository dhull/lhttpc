%%% ----------------------------------------------------------------------------
%%% Copyright (c) 2009, Erlang Training and Consulting Ltd.
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%    * Redistributions of source code must retain the above copyright
%%%      notice, this list of conditions and the following disclaimer.
%%%    * Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%    * Neither the name of Erlang Training and Consulting Ltd. nor the
%%%      names of its contributors may be used to endorse or promote products
%%%      derived from this software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY Erlang Training and Consulting Ltd. ''AS IS''
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL Erlang Training and Consulting Ltd. BE
%%% LIABLE SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
%%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
%%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
%%% ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%% ----------------------------------------------------------------------------

%%% @private
%%% @author Oscar Hellström <oscar@hellstrom.st>
%%% @doc
%%% This module implements the HTTP request handling. This should normally
%%% not be called directly since it should be spawned by the lhttpc module.
-module(lhttpc_client).

-export([request/11, stats_call/2]).

-include("lhttpc_types.hrl").

-record(client_state, {
        req_id :: term(),
        host :: string(),
        port = 80 :: integer(),
        ssl = false :: true | false,
        method :: string(),
        request :: iolist() | undefined,
        request_headers :: headers(),
        socket,
        connect_timeout = infinity :: timeout(),
        connect_options = [] :: [any()],
        attempts :: integer(),
        requester :: pid(),
        partial_upload = false :: true | false,
        chunked_upload = false :: true | false,
        upload_window :: non_neg_integer() | infinity,
        partial_download = false :: true | false,
        download_window = infinity :: timeout(),
        part_size :: non_neg_integer() | infinity
        %% in case of infinity we read whatever data we can get from
        %% the wire at that point or in case of chunked one chunk
    }).

-spec request(term(), pid(), string(), 1..65535, true | false, string(),
        string() | atom(), headers(), iodata(), lhttpc_stats_state(), [option()]) -> no_return().
%% @spec (ReqId, From, Host, Port, Ssl, Path, Method, Hdrs, RequestBody, StatsFun, Options) -> ok
%%    ReqId = term()
%%    From = pid()
%%    Host = string()
%%    Port = integer()
%%    Ssl = boolean()
%%    Method = atom() | string()
%%    Hdrs = [Header]
%%    Header = {string() | atom(), string()}
%%    Body = iodata()
%%    StatsState = lhttpc_stats_state()
%%    Options = [Option]
%%    Option = {connect_timeout, Milliseconds}
%% @end
request(ReqId, From, Host, Port, Ssl, Path, Method, Hdrs, Body, StatsState, Options) ->
    Result = try
        execute(ReqId, From, Host, Port, Ssl, Path, Method, Hdrs, Body, Options)
    catch
        throw:Reason ->
            {response, ReqId, self(), {error, Reason}};
        error:closed ->
            {response, ReqId, self(), {error, connection_closed}};
        error:Error ->
            {exit, ReqId, self(), {Error, erlang:get_stacktrace()}}
    end,
    stats_call(StatsState, case Result of {_, _, _, {ok, _}} -> normal; _ -> error end),
    case Result of
        {response, _, _, {ok, {no_return, _}}} -> ok;
        _Else                               -> From ! Result
    end,
    % Don't send back {'EXIT', self(), normal} if the process
    % calling us is trapping exits
    unlink(From),
    ok.

stats_call(undefined, _) -> ok;
stats_call(#lhttpc_stats_state{stats_fun=StatsFun, start_time=StartTime}, ResultType) ->
    StatsFun(ResultType, erlang:monotonic_time() - StartTime).

execute(ReqId, From, Host, Port, Ssl, Path, Method, Hdrs, Body, Options) ->
    UploadWindowSize = proplists:get_value(partial_upload, Options),
    PartialUpload = proplists:is_defined(partial_upload, Options),
    PartialDownload = proplists:is_defined(partial_download, Options),
    PartialDownloadOptions = proplists:get_value(partial_download, Options, []),
    NormalizedMethod = lhttpc_lib:normalize_method(Method),
    MaxConnections = proplists:get_value(max_connections, Options, 10),
    ConnectionTimeout = proplists:get_value(connection_timeout, Options, infinity),
    RequestLimit = proplists:get_value(request_limit, Options, infinity),
    ConnectionLifetime = proplists:get_value(connection_lifetime, Options, infinity),
    {ChunkedUpload, Request} = lhttpc_lib:format_request(Path, NormalizedMethod,
        Hdrs, Host, Port, Body, PartialUpload),
    %% BaseAttempts is 2 for an existing socket because we may find that the
    %% socket has been closed when we use it and we want to open a new socket
    %% and retry at least once in that case.
    {Socket, Lb, ConnInfo, BaseAttempts} =
        case lhttpc_lb:checkout(Host, Port, Ssl, MaxConnections, ConnectionTimeout, RequestLimit, ConnectionLifetime) of
            {ok, Lb0, CI0, S}     -> {S, Lb0, CI0, 2};          % Re-using HTTP/1.1 connections
            {no_socket, Lb0, CI0} -> {undefined, Lb0, CI0, 1};  % Opening a new HTTP/1.1 connection
            retry_later           -> throw(retry_later)
        end,
    State = #client_state{
        req_id = ReqId,
        host = Host,
        port = Port,
        ssl = Ssl,
        method = NormalizedMethod,
        request = Request,
        requester = From,
        request_headers = Hdrs,
        socket = Socket,
        connect_timeout = proplists:get_value(connect_timeout, Options,
            infinity),
        connect_options = proplists:get_value(connect_options, Options, []),
        attempts = BaseAttempts + proplists:get_value(send_retry, Options, 0),
        partial_upload = PartialUpload,
        upload_window = UploadWindowSize,
        chunked_upload = ChunkedUpload,
        partial_download = PartialDownload,
        download_window = proplists:get_value(window_size,
            PartialDownloadOptions, infinity),
        part_size = proplists:get_value(part_size,
            PartialDownloadOptions, infinity)
    },
    Response = case send_request(State) of
        {R, undefined} ->
            {ok, R};
        {R, NewSocket} ->
            %% Return the socket used for the request to the pool.  This may
            %% not be the same socket that the pool gave us; if so we need to
            %% transfer ownership to the pool.
            lhttpc_lb:checkin(Lb, ConnInfo, Ssl, NewSocket, NewSocket =/= Socket),
            {ok, R}
    end,
    {response, ReqId, self(), Response}.

send_request(#client_state{attempts = 0}) ->
    % Don't try again if the number of allowed attempts is 0.
    throw(connection_closed);
send_request(#client_state{socket = undefined} = State) ->
    Host = State#client_state.host,
    Port = State#client_state.port,
    Ssl = State#client_state.ssl,
    Timeout = State#client_state.connect_timeout,
    ConnectOptions = State#client_state.connect_options,
    SocketOptions = [binary, {packet, http}, {active, false} | ConnectOptions],
    case lhttpc_sock:connect(Host, Port, SocketOptions, Timeout, Ssl) of
        {ok, Socket} ->
            lhttpc_stats:record(open_connection, {{Host, Port, Ssl}, Socket}),
            send_request(State#client_state{socket = Socket});
        {error, etimedout} ->
            % TCP stack decided to give up
            lhttpc_stats:record(open_connection_error, {Host, Port, Ssl}),
            throw(connect_timeout);
        {error, timeout} ->
            lhttpc_stats:record(open_connection_error, {Host, Port, Ssl}),
            throw(connect_timeout);
        {error, Reason} ->
            lhttpc_stats:record(open_connection_error, {Host, Port, Ssl}),
            erlang:error(Reason)
    end;
send_request(State) ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    Request = State#client_state.request,
    lhttpc_stats:record(start_request, {{State#client_state.host, State#client_state.port, Ssl}, Socket, self()}),
    case lhttpc_sock:send(Socket, Request, Ssl) of
        ok ->
            if
                State#client_state.partial_upload     -> partial_upload(State);
                not State#client_state.partial_upload -> read_response(State)
            end;
        {error, closed} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            lhttpc_sock:close(Socket, Ssl),
            NewState = State#client_state{
                socket = undefined,
                attempts = State#client_state.attempts - 1
            },
            send_request(NewState);
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            lhttpc_sock:close(Socket, Ssl),
            erlang:error(Reason)
    end.

partial_upload(State) ->
    Response = {ok, {self(), State#client_state.upload_window}},
    State#client_state.requester ! {response,State#client_state.req_id, self(), Response},
    partial_upload_loop(State#client_state{attempts = 1, request = undefined}).

partial_upload_loop(State = #client_state{requester = Pid}) ->
    receive
        {trailers, Pid, Trailers} ->
            send_trailers(State, Trailers),
            read_response(State);
        {body_part, Pid, http_eob} ->
            send_body_part(State, http_eob),
            read_response(State);
        {body_part, Pid, Data} ->
            send_body_part(State, Data),
            Pid ! {ack, self()},
            partial_upload_loop(State)
    end.

send_body_part(State = #client_state{socket = Socket, ssl = Ssl}, BodyPart) ->
    Data = encode_body_part(State, BodyPart),
    check_send_result(State, lhttpc_sock:send(Socket, Data, Ssl)).

send_trailers(State = #client_state{chunked_upload = true}, Trailers) ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    Data = [<<"0\r\n">>, lhttpc_lib:format_hdrs(Trailers)],
    check_send_result(State, lhttpc_sock:send(Socket, Data, Ssl));
send_trailers(#client_state{chunked_upload = false}, _Trailers) ->
    erlang:error(trailers_not_allowed).

encode_body_part(#client_state{chunked_upload = true}, http_eob) ->
    <<"0\r\n\r\n">>; % We don't send trailers after http_eob
encode_body_part(#client_state{chunked_upload = false}, http_eob) ->
    <<>>;
encode_body_part(#client_state{chunked_upload = true}, Data) ->
    Size = list_to_binary(erlang:integer_to_list(iolist_size(Data), 16)),
    [Size, <<"\r\n">>, Data, <<"\r\n">>];
encode_body_part(#client_state{chunked_upload = false}, Data) ->
    Data.

check_send_result(_State, ok) ->
    ok;
check_send_result(#client_state{socket = Sock, ssl = Ssl}, {error, Reason}) ->
    lhttpc_stats:record(close_connection_remote, Sock),
    lhttpc_sock:close(Sock, Ssl),
    throw(Reason).

read_response(#client_state{socket = Socket, ssl = Ssl} = State) ->
    lhttpc_sock:setopts(Socket, [{packet, http}], Ssl),
    read_response(State, nil, {nil, nil}, []).

read_response(State, Vsn, {StatusCode, _} = Status, Hdrs) ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    case lhttpc_sock:recv(Socket, Ssl) of
        {ok, {http_response, NewVsn, NewStatusCode, Reason}} ->
            NewStatus = {NewStatusCode, Reason},
            read_response(State, NewVsn, NewStatus, Hdrs);
        {ok, {http_header, _, Name, _, Value}} ->
            Header = {lhttpc_lib:maybe_atom_to_list(Name), Value},
            read_response(State, Vsn, Status, [Header | Hdrs]);
        {ok, http_eoh} when StatusCode >= 100, StatusCode =< 199 ->
            % RFC 2616, section 10.1:
            % A client MUST be prepared to accept one or more
            % 1xx status responses prior to a regular
            % response, even if the client does not expect a
            % 100 (Continue) status message. Unexpected 1xx
            % status responses MAY be ignored by a user agent.
            read_response(State, nil, {nil, nil}, []);
        {ok, http_eoh} ->
            lhttpc_sock:setopts(Socket, [{packet, raw}], Ssl),
            Response = handle_response_body(State, Vsn, Status, Hdrs),
            NewHdrs = element(2, Response),
            ReqHdrs = State#client_state.request_headers,
            NewSocket = maybe_close_socket(Socket, Ssl, Vsn, ReqHdrs, NewHdrs),
            {Response, NewSocket};
        {error, closed} ->
            % Either we only noticed that the socket was closed after we
            % sent the request, the server closed it just after we put
            % the request on the wire or the server has some issues and is
            % closing connections without sending responses.
            % If this the first attempt to send the request, we will try again.
            lhttpc_stats:record(close_connection_remote, Socket),
            lhttpc_sock:close(Socket, Ssl),
            NewState = State#client_state{
                socket = undefined,
                attempts = State#client_state.attempts - 1
            },
            send_request(NewState);
        {error, timeout} ->
            lhttpc_stats:record(close_connection_timeout, Socket),
            lhttpc_sock:close(Socket, Ssl),
            NewState = State#client_state{
                socket = undefined,
                attempts = 0
            },
            send_request(NewState)
    end.

handle_response_body(#client_state{partial_download = false} = State, Vsn,
        Status, Hdrs) ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    Method = State#client_state.method,
    {Body, NewHdrs} = case has_body(Method, element(1, Status), Hdrs) of
        true  -> read_body(Vsn, Hdrs, Ssl, Socket, body_type(Hdrs));
        false -> {<<>>, Hdrs}
    end,
    {Status, NewHdrs, Body};
handle_response_body(#client_state{partial_download = true} = State, Vsn,
        Status, Hdrs) ->
    Method = State#client_state.method,
    case has_body(Method, element(1, Status), Hdrs) of
        true ->
            Response = {ok, {Status, Hdrs, self()}},
            State#client_state.requester ! {response, State#client_state.req_id, self(), Response},
            MonRef = erlang:monitor(process, State#client_state.requester),
            Res = read_partial_body(State, Vsn, Hdrs, body_type(Hdrs)),
            erlang:demonitor(MonRef, [flush]),
            Res;
        false ->
            {Status, Hdrs, undefined}
    end.

has_body("HEAD", _, _) ->
    % HEAD responses aren't allowed to include a body
    false;
has_body("OPTIONS", _, Hdrs) ->
    % OPTIONS can include a body, if Content-Length or Transfer-Encoding
    % indicates it
    ContentLength = lhttpc_lib:header_value("content-length", Hdrs),
    TransferEncoding = lhttpc_lib:header_value("transfer-encoding", Hdrs),
    case {ContentLength, TransferEncoding} of
        {undefined, undefined} -> false;
        {_, _}                 -> true
    end;
has_body(_, 204, _) ->
    false; % RFC 2616 10.2.5: 204 No Content
has_body(_, 304, _) ->
    false; % RFC 2616 10.3.5: 304 Not Modified
has_body(_, _, _) ->
    true. % All other responses are assumed to have a body

body_type(Hdrs) ->
    % Find out how to read the entity body from the request.
    % * If we have a Content-Length, just use that and read the complete
    %   entity.
    % * If Transfer-Encoding is set to chunked, we should read one chunk at
    %   the time
    % * If neither of this is true, we need to read until the socket is
    %   closed (AFAIK, this was common in versions before 1.1).
    case lhttpc_lib:header_value("content-length", Hdrs) of
        undefined ->
            case lhttpc_lib:header_value("transfer-encoding", Hdrs) of
                undefined    -> infinite;
                TransferEncoding ->
                    case lhttpc_lib:string_lower_equal("chunked", TransferEncoding) of
                        true -> chunked;
                        _    -> infinite
                    end
            end;
        ContentLength ->
            {fixed_length, list_to_integer(ContentLength)}
    end.

read_partial_body(State, _Vsn, Hdrs, chunked) ->
    Window = State#client_state.download_window,
    read_partial_chunked_body(State, Hdrs, Window, 0, [], 0);
read_partial_body(State, Vsn, Hdrs, infinite) ->
    check_infinite_response(Vsn, Hdrs),
    read_partial_infinite_body(State, Hdrs, State#client_state.download_window);
read_partial_body(State, _Vsn, Hdrs, {fixed_length, ContentLength}) ->
    read_partial_finite_body(State, Hdrs, ContentLength,
        State#client_state.download_window).

read_body(_Vsn, Hdrs, Ssl, Socket, chunked) ->
    read_chunked_body(Socket, Ssl, Hdrs, []);
read_body(Vsn, Hdrs, Ssl, Socket, infinite) ->
    check_infinite_response(Vsn, Hdrs),
    read_infinite_body(Socket, Hdrs, Ssl);
read_body(_Vsn, Hdrs, Ssl, Socket, {fixed_length, ContentLength}) ->
    read_length(Hdrs, Ssl, Socket, ContentLength).

read_partial_finite_body(State = #client_state{}, Hdrs, 0, _Window) ->
    reply_end_of_body(State, [], Hdrs);
read_partial_finite_body(State = #client_state{requester = To}, Hdrs,
        ContentLength, 0) ->
    receive
        {ack, To} ->
            read_partial_finite_body(State, Hdrs, ContentLength, 1);
        {'DOWN', _, process, To, _} ->
            exit(normal)
    end;
read_partial_finite_body(State, Hdrs, ContentLength, Window) when Window >= 0->
    Bin = read_body_part(State, ContentLength),
    State#client_state.requester ! {body_part, self(), Bin},
    To = State#client_state.requester,
    receive
        {ack, To} ->
            Length = ContentLength - iolist_size(Bin),
            read_partial_finite_body(State, Hdrs, Length, Window);
        {'DOWN', _, process, To, _} ->
            exit(normal)
    after 0 ->
            Length = ContentLength - iolist_size(Bin),
        read_partial_finite_body(State, Hdrs, Length, lhttpc_lib:dec(Window))
    end.

read_body_part(#client_state{part_size = infinity} = State, _ContentLength) ->
    case lhttpc_sock:recv(State#client_state.socket, State#client_state.ssl) of
        {ok, Data} ->
            Data;
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, State#client_state.socket),
            erlang:error(Reason)
    end;
read_body_part(#client_state{part_size = PartSize} = State, ContentLength)
        when PartSize =< ContentLength ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    PartSize = State#client_state.part_size,
    case lhttpc_sock:recv(Socket, PartSize, Ssl) of
        {ok, Data} ->
            Data;
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end;
read_body_part(#client_state{part_size = PartSize} = State, ContentLength)
        when PartSize > ContentLength ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    case lhttpc_sock:recv(Socket, ContentLength, Ssl) of
        {ok, Data} ->
            Data;
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

read_length(Hdrs, Ssl, Socket, Length) ->
    case lhttpc_sock:recv(Socket, Length, Ssl) of
        {ok, Data} ->
            {Data, Hdrs};
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

read_partial_chunked_body(State, Hdrs, Window, BufferSize, Buffer, 0) ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    PartSize = State#client_state.part_size,
    case read_chunk_size(Socket, Ssl) of
        0 ->
            reply_chunked_part(State, Buffer, Window),
            {Trailers, NewHdrs} = read_trailers(Socket, Ssl, [], Hdrs),
            reply_end_of_body(State, Trailers, NewHdrs);
        ChunkSize when PartSize =:= infinity ->
            Chunk = read_chunk(Socket, Ssl, ChunkSize),
            NewWindow = reply_chunked_part(State, [Chunk | Buffer], Window),
            read_partial_chunked_body(State, Hdrs, NewWindow, 0, [], 0);
        ChunkSize when BufferSize + ChunkSize >= PartSize ->
            {Chunk, RemSize} = read_partial_chunk(Socket, Ssl,
                PartSize - BufferSize, ChunkSize),
            NewWindow = reply_chunked_part(State, [Chunk | Buffer], Window),
            read_partial_chunked_body(State, Hdrs, NewWindow, 0, [], RemSize);
        ChunkSize ->
            Chunk = read_chunk(Socket, Ssl, ChunkSize),
            read_partial_chunked_body(State, Hdrs, Window,
                BufferSize + ChunkSize, [Chunk | Buffer], 0)
    end;
read_partial_chunked_body(State, Hdrs, Window, BufferSize, Buffer, RemSize) ->
    Socket = State#client_state.socket,
    Ssl = State#client_state.ssl,
    PartSize = State#client_state.part_size,
    if
        BufferSize + RemSize >= PartSize ->
            {Chunk, NewRemSize} =
                read_partial_chunk(Socket, Ssl, PartSize - BufferSize, RemSize),
            NewWindow = reply_chunked_part(State, [Chunk | Buffer], Window),
            read_partial_chunked_body(State, Hdrs, NewWindow, 0, [],
                NewRemSize);
        BufferSize + RemSize < PartSize ->
            Chunk = read_chunk(Socket, Ssl, RemSize),
            read_partial_chunked_body(State, Hdrs, Window, BufferSize + RemSize,
                [Chunk | Buffer], 0)
    end.

read_chunk_size(Socket, Ssl) ->
    lhttpc_sock:setopts(Socket, [{packet, line}], Ssl),
    case lhttpc_sock:recv(Socket, Ssl) of
        {ok, ChunkSizeExt} ->
            chunk_size(ChunkSizeExt);
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

reply_chunked_part(_State, [], Window) ->
    Window;
reply_chunked_part(State = #client_state{requester = Pid}, Buff, 0) ->
    receive
        {ack, Pid} ->
            reply_chunked_part(State, Buff, 1);
        {'DOWN', _, process, Pid, _} ->
            exit(normal)
    end;
reply_chunked_part(#client_state{requester = Pid}, Buffer, Window) ->
    Pid ! {body_part, self(), list_to_binary(lists:reverse(Buffer))},
    receive
        {ack, Pid} ->  Window;
        {'DOWN', _, process, Pid, _} -> exit(normal)
    after 0 ->
        lhttpc_lib:dec(Window)
    end.

read_chunked_body(Socket, Ssl, Hdrs, Chunks) ->
    case read_chunk_size(Socket, Ssl) of
        0 ->
            Body = list_to_binary(lists:reverse(Chunks)),
            {_, NewHdrs} = read_trailers(Socket, Ssl, [], Hdrs),
            {Body, NewHdrs};
        Size ->
            Chunk = read_chunk(Socket, Ssl, Size),
            read_chunked_body(Socket, Ssl, Hdrs, [Chunk | Chunks])
    end.

chunk_size(Bin) ->
    erlang:list_to_integer(lists:reverse(chunk_size(Bin, [])), 16).

chunk_size(<<$;, _/binary>>, Chars) ->
    Chars;
chunk_size(<<"\r\n", _/binary>>, Chars) ->
    Chars;
chunk_size(<<$\s, Binary/binary>>, Chars) ->
    %% Facebook's HTTP server returns a chunk size like "6  \r\n"
    chunk_size(Binary, Chars);
chunk_size(<<Char, Binary/binary>>, Chars) ->
    chunk_size(Binary, [Char | Chars]).

read_partial_chunk(Socket, Ssl, ChunkSize, ChunkSize) ->
    {read_chunk(Socket, Ssl, ChunkSize), 0};
read_partial_chunk(Socket, Ssl, Size, ChunkSize) ->
    lhttpc_sock:setopts(Socket, [{packet, raw}], Ssl),
    case lhttpc_sock:recv(Socket, Size, Ssl) of
        {ok, Chunk} ->
            {Chunk, ChunkSize - Size};
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

read_chunk(Socket, Ssl, Size) ->
    lhttpc_sock:setopts(Socket, [{packet, raw}], Ssl),
    case lhttpc_sock:recv(Socket, Size + 2, Ssl) of
        {ok, <<Chunk:Size/binary, "\r\n">>} ->
            Chunk;
        {ok, Data} ->
            erlang:error({invalid_chunk, Data});
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

read_trailers(Socket, Ssl, Trailers, Hdrs) ->
    lhttpc_sock:setopts(Socket, [{packet, httph}], Ssl),
    case lhttpc_sock:recv(Socket, Ssl) of
        {ok, http_eoh} ->
            {Trailers, Hdrs};
        {ok, {http_header, _, Name, _, Value}} ->
            Header = {lhttpc_lib:maybe_atom_to_list(Name), Value},
            read_trailers(Socket, Ssl, [Header | Trailers], [Header | Hdrs]);
        {error, {http_error, Data}} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error({bad_trailer, Data})
    end.

reply_end_of_body(#client_state{requester = Requester}, Trailers, Hdrs) ->
    Requester ! {http_eob, self(), Trailers},
    {no_return, Hdrs}.

read_partial_infinite_body(State = #client_state{requester = To}, Hdrs, 0) ->
    receive
        {ack, To} ->
            read_partial_infinite_body(State, Hdrs, 1);
        {'DOWN', _, process, To, _} ->
            exit(normal)
    end;
read_partial_infinite_body(State = #client_state{requester = To}, Hdrs, Window)
        when Window >= 0 ->
    case read_infinite_body_part(State) of
        http_eob -> reply_end_of_body(State, [], Hdrs);
        Bin ->
            State#client_state.requester ! {body_part, self(), Bin},
            receive
                {ack, To} ->
                    read_partial_infinite_body(State, Hdrs, Window);
                {'DOWN', _, process, To, _} ->
                    exit(normal)
            after 0 ->
                read_partial_infinite_body(State, Hdrs, lhttpc_lib:dec(Window))
            end
    end.

read_infinite_body_part(#client_state{socket = Socket, ssl = Ssl}) ->
    case lhttpc_sock:recv(Socket, Ssl) of
        {ok, Data} ->
            Data;
        {error, closed} ->
            http_eob;
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

check_infinite_response({1, Minor}, Hdrs) when Minor >= 1 ->
    HdrValue = lhttpc_lib:header_value("connection", Hdrs, "keep-alive"),
    case lhttpc_lib:string_lower_equal("close", HdrValue) of
        true -> ok;
        _    -> erlang:error(no_content_length)
    end;
check_infinite_response(_, Hdrs) ->
    HdrValue = lhttpc_lib:header_value("connection", Hdrs, "close"),
    case lhttpc_lib:string_lower_equal("keep-alive", HdrValue) of
        true -> erlang:error(no_content_length);
        _    -> ok
    end.

read_infinite_body(Socket, Hdrs, Ssl) ->
    read_until_closed(Socket, <<>>, Hdrs, Ssl).

read_until_closed(Socket, Acc, Hdrs, Ssl) ->
    case lhttpc_sock:recv(Socket, Ssl) of
        {ok, Body} ->
            NewAcc = <<Acc/binary, Body/binary>>,
            read_until_closed(Socket, NewAcc, Hdrs, Ssl);
        {error, closed} ->
            {Acc, Hdrs};
        {error, Reason} ->
            lhttpc_stats:record(close_connection_remote, Socket),
            erlang:error(Reason)
    end.

maybe_close_socket(Socket, Ssl, {1, Minor}, ReqHdrs, RespHdrs) when Minor >= 1->
    ClientConnectionIsClose = lhttpc_lib:string_lower_equal("close", lhttpc_lib:header_value("connection", ReqHdrs, "keep-alive")),
    ServerConnectionIsClose = lhttpc_lib:string_lower_equal("close", lhttpc_lib:header_value("connection", RespHdrs, "keep-alive")),
    if
        ClientConnectionIsClose ->
            lhttpc_stats:record(close_connection_local, Socket),
            lhttpc_sock:close(Socket, Ssl),
            undefined;
        ServerConnectionIsClose ->
            lhttpc_stats:record(close_connection_remote, Socket),
            lhttpc_sock:close(Socket, Ssl),
            undefined;
        true ->
            Socket
    end;
maybe_close_socket(Socket, Ssl, _, ReqHdrs, RespHdrs) ->
    ClientConnectionIsClose = lhttpc_lib:string_lower_equal("close", lhttpc_lib:header_value("connection", ReqHdrs, "keep-alive")),
    ServerConnectionIsKeepAlive = lhttpc_lib:string_lower_equal("keep-alive", lhttpc_lib:header_value("connection", RespHdrs, "close")),
    if
        ClientConnectionIsClose ->
            lhttpc_stats:record(close_connection_local, Socket),
            lhttpc_sock:close(Socket, Ssl),
            undefined;
        not ServerConnectionIsKeepAlive ->
            lhttpc_stats:record(close_connection_remote, Socket),
            lhttpc_sock:close(Socket, Ssl),
            undefined;
        true ->
            Socket
    end.
