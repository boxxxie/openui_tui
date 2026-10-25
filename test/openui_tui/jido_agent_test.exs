defmodule OpenUITUI.JidoAgentTest do
  use ExUnit.Case, async: false

  alias OpenUITUI.LLMTelemetry.Parser, as: LLMTelemetryParser
  alias OpenUITUI.Studio.Actions.ClassifyIntent
  alias OpenUITUI.Studio.{Agent, Session, Store}

  test "OpenUITUI.Jido supervisor is running and Studio.Agent exposes 5 Jido.Action tools" do
    assert is_pid(Process.whereis(OpenUITUI.Jido))

    tools = Agent.registered_tools()
    tool_names = Enum.map(tools, fn t -> t[:name] || t["name"] end)

    assert "classify_studio_intent" in tool_names
    assert "create_studio_app" in tool_names
    assert "switch_studio_model" in tool_names
    assert "answer_studio_question" in tool_names
    assert "evolve_openui_ast" in tool_names
  end

  test "Studio.Agent executes SwitchModel action via Jido.Exec and updates immutable agent state" do
    app = %{"id" => "memcached-live", "revision" => 1, "messages" => []}
    agent = Agent.new_for_app(app, "gemini-3.8-flash", nil)

    assert agent.state.model == "gemini-3.8-flash"
    assert agent.state.reasoning_effort == nil

    {:ok, updated_agent, res} =
      Agent.switch_model(agent, %{
        prompt: "use argon low",
        target_model: "gemini-4-argon",
        reasoning_effort: "low",
        revision: 1,
        statement_count: 24,
        intent_info: %{prompt_tokens: 120, completion_tokens: 30, cache_status: :hit}
      })

    assert updated_agent.state.model == "gemini-4-argon"
    assert updated_agent.state.reasoning_effort == "low"
    assert updated_agent.state.turns == 1
    assert res.model_badge == "gemini-4-argon (low)"
    assert res.answer_text =~ "gemini-4-argon (low)"
  end

  test "ClassifyIntent.resolve_model_switch resolves argon low, gemini variants, and create_new_app" do
    assert {"switch_model", "gemini-4-argon", "low"} =
             ClassifyIntent.resolve_model_switch(
               "use argon low",
               %{intent: "switch_model", target_model: "gemini-4-argon", reasoning_effort: "low"},
               "gemini-3.8-flash",
               nil
             )

    assert {"create_new_app", "gemini-3.8-flash", nil} =
             ClassifyIntent.resolve_model_switch(
               "make new app",
               %{
                 intent: "build_or_modify_ui",
                 target_model: "keep_current",
                 reasoning_effort: "default"
               },
               "gemini-3.8-flash",
               nil
             )

    assert {"create_new_app", "gemini-3.8-flash", nil} =
             ClassifyIntent.resolve_model_switch(
               "make a new app for llm metrics for the openui_tui app itself",
               %{
                 intent: "build_or_modify_ui",
                 target_model: "keep_current",
                 reasoning_effort: "default"
               },
               "gemini-3.8-flash",
               nil
             )
  end

  test "LLMTelemetry.Parser aggregates real Gemini & TypeSafe Jev telemetry without fake models" do
    bindings = LLMTelemetryParser.collect_live_bindings()

    assert is_binary(bindings["$llm_calls_kpi"])
    assert is_list(bindings["$llm_model_rows"])
    assert is_list(bindings["$llm_model_ids"])
    assert "gemini-3.8-flash" in bindings["$llm_model_ids"]
    assert "typesafe/jev-latest" in bindings["$llm_model_ids"]
    refute "gpt-4o" in bindings["$llm_model_ids"]
    refute "claude-3.5-sonnet" in bindings["$llm_model_ids"]
  end

  test "chatting 'make new app' or 'make a new app for llm metrics' creates a new app in the app list with its own isolated chat" do
    Store.with_sandbox(fn _tmp_dir ->
      {:ok, studio} = Session.start_link(app_id: "memcached-live", initial_tab: :split)

      # 1. Say "make new app" -> creates App #4 with its own chat, leaving memcached-live untouched
      {:ok, turn1} = Session.send_chat_message(studio, "make new app")
      assert turn1.jev_intent == "create_new_app"

      st1 = Session.get_state(studio)
      assert length(st1.apps_list) == 4
      assert st1.current_app["id"] != "memcached-live"
      assert st1.current_app["title"] == "New OpenUI App #4"
      assert length(st1.current_app["messages"]) == 2

      # Verify memcached-live was not modified or polluted with the prompt
      {:ok, mem_app} = Store.get_app("memcached-live")
      assert mem_app["title"] == "Memcached & BEAM Live Telemetry"
      assert length(mem_app["messages"]) == 2

      # 2. Say "make a new app for llm metrics for the openui_tui app itself"
      {:ok, turn2} =
        Session.send_chat_message(
          studio,
          "make a new app for llm metrics for the openui_tui app itself"
        )

      assert turn2.jev_intent == "create_new_app"

      st2 = Session.get_state(studio)
      assert length(st2.apps_list) == 5
      assert st2.current_app["title"] == "OpenUI TUI — LiteLLM & Jev Telemetry"
      assert length(st2.current_app["messages"]) == 2
      assert st2.live_info.active? == true
      assert "openui_telemetry(events.jsonl+SpendGuard)" in st2.live_info.sources

      rendered = Session.render_to_string(studio, width: 148, height: 36, ansi?: false)
      assert rendered =~ "OpenUI TUI — LiteLLM & Jev Telemetry"
      assert rendered =~ "typesafe/jev-latest"
      assert rendered =~ "gemini-3.8-flash"
      refute rendered =~ "gpt-4o"
      refute rendered =~ "claude-3.5-sonnet"
    end)
  end
end
