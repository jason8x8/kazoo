%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2012, James Aimonetti
%%% @doc
%%%
%%% Agent Callflow Data:
%%%   pin_retries :: integer()
%%%   min_digits :: integer()
%%%   max_digits :: integer()
%%%
%%% @end
%%% Created : 10 Jan 2012 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_agent).

-export([handle/2]).

-include("../callflow.hrl").

-record(prompts, {
          pin_prompt = <<"/system_media/hotdesk-enter_pin">>
         ,invalid_pin_prompt = <<"/system_media/conf-bad_pin">>
         ,retries_exceeded_prompt = <<"/system_media/conf-to_many_attempts">>
         ,welcome_prompt = <<"/system_media/vm-setup_complete">>
         ,logged_in_prompt = <<"/system_media/hotdesk-logged_in">>
         }).

-spec handle/2 :: (json_object(), #cf_call{}) -> 'ok'.
handle(Data, Call) ->
    case find_agent(Data, wh_json:get_integer_value(<<"pin_retries">>, Data, 3), Call) of
        {ok, AgentJObj} ->
            play_welcome(Call),
            put_on_hold(Call),
            publish_agent_available(AgentJObj, Call),
            cf_call_command:wait_for_hangup(),
            ?LOG("agent hungup"),
            publish_agent_unavailable(AgentJObj, Call);
        {error, _} ->
            cf_call_command:hangup(Call)
    end.

publish_agent_unavailable(AgentJObj, Call) ->
    ok.
    %send_unavailable(AgentJObj, Call).

publish_agent_available(AgentJObj, Call) ->
    ok.
    %send_available(AgentJObj, Call).

send_unavailable(AgentJObj, Call) ->
    Req = [{<<"Agent-ID">>, wh_json:get_value(<<"_id">>, AgentJObj)}
           ,{<<"Call-ID">>, cf_exe:callid(Call)}
           | wh_api:default_headers(<<>>, ?APP_NAME, ?APP_VERSION)],
    wapi_acd:publish_agent_offline(Req).

send_available(AgentJObj, Call) ->
    Req = [{<<"Agent-ID">>, wh_json:get_value(<<"_id">>, AgentJObj)}
           ,{<<"Skills">>, wh_json:get_value(<<"skills">>, AgentJObj, [])}
           ,{<<"Call-ID">>, cf_exe:callid(Call)}
           | wh_api:default_headers(<<>>, ?APP_NAME, ?APP_VERSION)],
    wapi_acd:publish_agent_online(Req).

put_on_hold(Call) ->
    cf_call_command:hold(Call).

play_welcome(Call) ->
    #prompts{welcome_prompt=WelcomePrompt} = #prompts{},
    
    cf_call_command:play(WelcomePrompt, Call).

prompt_and_get_pin(#prompts{pin_prompt=PinPrompt}, Data, Call) ->
    MinPinDigits = wh_json:get_integer_value(<<"min_digits">>, Data, 3),
    MaxPinDigits = wh_json:get_integer_value(<<"max_digits">>, Data, 5),

    cf_call_command:b_play_and_collect_digits(MinPinDigits, MaxPinDigits, PinPrompt, Call).

find_agent(_Data, 0, Call) ->
    ?LOG("retries exceeded"),
    #prompts{retries_exceeded_prompt=RetriesPrompt} = #prompts{},
    cf_call_command:play(RetriesPrompt, Call),
    {error, retries_exceeded};
find_agent(Data, Retries, #cf_call{account_db=Db}=Call) ->
    Prompts = #prompts{},
    case prompt_and_get_pin(Prompts, Data, Call) of
        {ok, Pin} -> % Pin = <<"315">>
            ?LOG("got ~s for pin", [Pin]),
            case couch_mgr:get_results(Db, <<"agent/listing_by_pin">>, [{<<"include_docs">>, true}, {<<"key">>, Pin}]) of
                {ok, []} ->
                    ?LOG("no agent found with pin"),
                    #prompts{invalid_pin_prompt=InvalidPinPrompt}=Prompts,
                    cf_call_command:b_play(InvalidPinPrompt, Call),
                    find_agent(Data, Retries-1, Call);
                {ok, [AgentJObj]} ->
                    ?LOG("agent found"),
                    {ok, AgentJObj};
                {error, _E} ->
                    ?LOG("error loading agent: ~p", [_E]),
                    #prompts{invalid_pin_prompt=InvalidPinPrompt}=Prompts,
                    cf_call_command:b_play(InvalidPinPrompt, Call),
                    find_agent(Data, Retries-1, Call)
            end;
        {error, _E} ->
            ?LOG("error getting pin: ~p", [_E]),
            cf_call_command:hangup(Call)
    end.
