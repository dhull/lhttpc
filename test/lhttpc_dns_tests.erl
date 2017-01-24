-module(lhttpc_dns_tests).

-include_lib("eunit/include/eunit.hrl").



-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-ifdef(EUNIT).

lhttpc_dns_disabled_test () ->
  %% Verify that if lhttpc_dns is not enabled that lhttpc_dns:lookup
  %% returns the original hostname.
  ?assertEqual("example.com", lhttpc_dns:lookup("example.com")).

lhttpc_dns_enabled_test_ () ->
  {inorder,
   {setup, fun lhttpc_dns:create_table/0, fun (_) -> lhttpc_dns:destroy_table() end,
    [ ?_test(test_lookup_uncached())
    , ?_test(test_lookup())
    ]}
  }.

test_lookup_uncached () ->
  {IPAddr0, _TTL0} = lhttpc_dns:lookup_uncached("localhost"),
  ?assertEqual({{127, 0, 0, 1}}, IPAddr0),
  {IPAddr1, _TTL1} = lhttpc_dns:lookup_uncached("not-a-real-hostname.com"),
  ?assertEqual(undefined, IPAddr1),
  {IPAddr2, _TTL2} = lhttpc_dns:lookup_uncached("93.184.216.119"),
  ?assertEqual({{93, 184, 216, 119}}, IPAddr2).


-define(LOCALHOST, {127, 0, 0, 1}).
-define(MULTI1, {2, 0, 0, 0}).
-define(MULTI2, {3, 0, 0, 0}).
-define(SINGLE, {4, 0, 0, 0}).

test_lookup () ->
  meck:new(lhttpc_dns, [ passthrough, no_passthrough_cover ]),
  meck:expect(lhttpc_dns, lookup_uncached,
              fun(Host) ->
                  %% io:format(standard_error, "host: ~p~n", [ Host ]),
                  case erlang:get(dns_fail) of
                    true ->
                      erlang:put(dns_fail, false),
                                            {undefined, 1};
                    false ->
                      case Host of
                        "localhost" ->      {{?LOCALHOST}, 3600};
                        "single.com" ->     {{?SINGLE}, 1800};
                        "multi.com" ->      {{?MULTI1, ?MULTI2}, 300};
                        _ ->                {undefined, 1}
                      end
                  end
              end),
  meck:expect(lhttpc_dns, os_timestamp,
              fun () -> { 0, erlang:get(dns_ts), 0 } end),

  meck:new(random, [ passthrough, unstick, no_passthrough_cover ]),
  meck:expect(random, uniform, fun (N) -> erlang:get(dns_random) rem N + 1 end),

  lhttpc_dns:reset_table(),
  erlang:put(dns_fail, false),
  erlang:put(dns_random, 0),
  erlang:put(dns_ts, 0),

  %% Verify that our function has been successfully mecked.
  ?assertEqual({{?LOCALHOST}, 3600}, lhttpc_dns:lookup_uncached("localhost")),

  %% Verify that IP address caching is working.
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 60),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 2400),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),

  %% When a hostname has multiple IP addresses, a random one is returned.
  erlang:put(dns_ts, 3600),
  ?assertEqual(?MULTI1, lhttpc_dns:lookup("multi.com")),
  erlang:put(dns_random, 1),
  ?assertEqual(?MULTI2, lhttpc_dns:lookup("multi.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "multi.com" ])),
  erlang:put(dns_ts, 3720),
  ?assertEqual(?MULTI2, lhttpc_dns:lookup("multi.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "multi.com" ])),

  %% When a DNS lookup for a cached hostname fails, the old value is cached
  %% for an additional MIN_CACHE_SECONDS.
  erlang:put(dns_ts, 7200),
  erlang:put(dns_fail, true),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(3, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 7201),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(3, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 7600),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(4, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 7601),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(4, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 8000),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(4, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),
  erlang:put(dns_ts, 10800),
  ?assertEqual(?SINGLE, lhttpc_dns:lookup("single.com")),
  ?assertEqual(5, meck:num_calls(lhttpc_dns, lookup_uncached, [ "single.com" ])),

  %% Error lookups are only cached for ERROR_CACHE_SECONDS.
  ?assertEqual(undefined, lhttpc_dns:lookup("noaddr.com")),
  ?assertEqual(undefined, lhttpc_dns:lookup("noaddr.com")),
  ?assertEqual(1, meck:num_calls(lhttpc_dns, lookup_uncached, [ "noaddr.com" ])),
  erlang:put(dns_ts, 10802),
  ?assertEqual(undefined, lhttpc_dns:lookup("noaddr.com")),
  ?assertEqual(2, meck:num_calls(lhttpc_dns, lookup_uncached, [ "noaddr.com" ])),

  meck:unload(random),
  meck:unload(lhttpc_dns).

-endif. % ifdef EUNIT
