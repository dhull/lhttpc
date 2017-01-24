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

%%% @author Oscar Hellström <oscar@hellstrom.st>
-module(lhttpc_lib_tests).

-include_lib("eunit/include/eunit.hrl").

parse_url_test_() ->
    [
        ?_assertEqual({"host", 80, "/", false},
            lhttpc_lib:parse_url("http://host")),
        ?_assertEqual({"host", 80, "/", false},
            lhttpc_lib:parse_url("http://host/")),
        ?_assertEqual({"host", 443, "/", true},
            lhttpc_lib:parse_url("https://host")),
        ?_assertEqual({"host", 443, "/", true},
            lhttpc_lib:parse_url("https://host/")),
        ?_assertEqual({"host", 180, "/", false},
            lhttpc_lib:parse_url("http://host:180")),
        ?_assertEqual({"host", 180, "/", false},
            lhttpc_lib:parse_url("http://host:180/")),
        ?_assertEqual({"host", 180, "/foo", false},
            lhttpc_lib:parse_url("http://host:180/foo")),
        ?_assertEqual({"host", 180, "/foo/bar", false},
            lhttpc_lib:parse_url("http://host:180/foo/bar")),
        ?_assertEqual({"host", 80, "?query", false},
            lhttpc_lib:parse_url("http://host?query")),
        ?_assertEqual({"host", 443, "?query", true},
            lhttpc_lib:parse_url("https://host?query")),
        ?_assertEqual({"host", 180, "?query", false},
            lhttpc_lib:parse_url("http://host:180?query"))
    ].


header_value_test_() ->
  Hdrs = [
           {"Accept-Encoding","gzip"}
          ,{"Access-Control-Allow-Methods","GET, POST, OPTIONS"}
          ,{"Bid-Request-End-Time","1482516525448"}
          ,{"Bid-Request-Start-Time","1482516525430"}
          ,{"Content-Encoding","gzip"}
          ,{"Content-Length","1034"}
          ,{"Expires","Tue, 11 Oct 1977 12:34:56 GMT"}
          ,{"Host","10.5.75.249"}
          ,{"P3p","CP=\"NON DEVa PSAa PSDa OUR NOR NAV\",policyref=\"/w3c/p3p.xml\""}
          ,{"X-Frame-Options","SAMEORIGIN"}
          ,{"X-OpenX-Id","0050ac11-8170-189d-2915-5e00ce817498"}
          ,{"X-OpenX-Rtb","b7f40ed1-c62a-11e6-bfe1-005056a21a26"}
          ,{"accept","application/json"}
          ,{"content-type","application/json"}
          ,{"x-openrtb-version","2.4"}
          ,{"ABCDEFGHIJKLMNOPQRSTUVWXYZ-","alpha-minus"}
        ],
  [
        ?_assertEqual("1034",    lhttpc_lib:header_value("content-length", Hdrs, undefined))
       ,?_assertEqual("10.5.75.249", lhttpc_lib:header_value("host", Hdrs, undefined))
       ,?_assertEqual("CP=\"NON DEVa PSAa PSDa OUR NOR NAV\",policyref=\"/w3c/p3p.xml\"", lhttpc_lib:header_value("p3p", Hdrs, undefined))
       ,?_assertEqual(undefined, lhttpc_lib:header_value("content", Hdrs, undefined))
       ,?_assertEqual(undefined, lhttpc_lib:header_value("content-length1", Hdrs, undefined))
       ,?_assertEqual(undefined, lhttpc_lib:header_value("content-length1", [], undefined))
       ,?_assertEqual(undefined, lhttpc_lib:header_value([], [], undefined))
       ,?_assertEqual("alpha-minus", lhttpc_lib:header_value("abcdefghijklmnopqrstuvwxyz-", Hdrs, undefined))
  ].
