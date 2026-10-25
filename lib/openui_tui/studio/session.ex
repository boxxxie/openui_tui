defmodule OpenUITUI.Studio.Session do
  @moduledoc """
  Stateful GenServer for an OpenUI Studio workspace where every Conversation is an App.

  Coordinates:
  - Active Tab (`:chat`, `:app`, `:split`, `:code`, `:apps`) with instant `Tab` toggling between `:chat` and `:app`
  - Underlying `OpenUITUI.LiveSession` process running the current app's `StreamSource` and `Bind` data plane
  - Multi-turn conversational app evolution with `OpenUILang.merge_statements/2`, revision history (`/undo`), and `OpenUITUI.CrashReporter` safety boundaries
  - Recursive interactive widget discovery & focus navigation (`Field`, `Select`, `Toggle`, `Button`) inside `:app` and `:split` views
  - `@ToAssistant(...)` button action dispatch from the app back into the chat conversation
  """

  use GenServer

  alias OpenUITUI.{CrashReporter, LiveSession}
  alias OpenUITUI.Studio.{Agent, Chrome, Store}

  @renderers ["fixed_80", "owl", "pure_ansi", "table_rex", "compact_ops"]

  defstruct active_tab: :chat,
            prev_tab: :chat,
            chat_in_flight?: false,
            model: "gemini-3.8-flash",
            reasoning_effort: nil,
            jido_agent: nil,
            current_app: nil,
            apps_list: [],
            live_session: nil,
            controls: [],
            focused_control_idx: 0,
            input_buffer: "",
            status_message:
              "Ready — Type a message and press [Enter], or press [Tab] to switch view",
            tick: 0

  @type tab :: :chat | :app | :split | :code | :apps

  # ── Client API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Toggles between the `:chat` tab and the `:app` (Live App) tab when the user presses `Tab`.
  """
  @spec toggle_chat_app_tab(GenServer.server()) :: {:ok, tab()}
  def toggle_chat_app_tab(server) do
    GenServer.call(server, :toggle_chat_app_tab)
  end

  @doc """
  Switches directly to `:chat`, `:app`, `:split`, `:code`, or `:apps`.
  """
  @spec switch_tab(GenServer.server(), tab()) :: {:ok, tab()}
  def switch_tab(server, tab) when tab in [:chat, :app, :split, :code, :apps] do
    GenServer.call(server, {:switch_tab, tab})
  end

  @doc """
  Updates the live prompt input buffer in raw keystroke TUI mode.
  """
  @spec update_input_buffer(
          GenServer.server(),
          :backspace | {:append, String.t()} | {:set, String.t()}
        ) ::
          {:ok, String.t()}
  def update_input_buffer(server, op) do
    GenServer.call(server, {:update_input_buffer, op})
  end

  @doc """
  Stages a user prompt into the conversation history immediately (along with a temporary
  `⟳ Generating...` assistant bubble) so the UI can redraw before the synchronous LLM call runs.
  """
  @spec stage_user_prompt(GenServer.server(), String.t()) :: :ok
  def stage_user_prompt(server, prompt) when is_binary(prompt) do
    GenServer.call(server, {:stage_user_prompt, prompt})
  end

  @doc """
  Sends a user prompt in the current conversation to build or update the App UI.
  Wrapped in a crash-safe boundary that writes to `OpenUITUI.CrashReporter` on error.
  """
  @spec send_chat_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_chat_message(server, prompt, opts \\ []) when is_binary(prompt) do
    GenServer.call(server, {:send_chat_message, prompt, opts}, 45_000)
  end

  @doc """
  Applies a direct OpenUI Lang statement patch to the current app (via `OpenUILang.merge_statements/2`).
  """
  @spec patch_app_code(GenServer.server(), String.t(), String.t()) :: {:ok, map()}
  def patch_app_code(server, patch_code, note \\ "Patched OpenUI statements") do
    GenServer.call(server, {:patch_app_code, patch_code, note})
  end

  @doc """
  Reverts the current app to its previous revision from `history`.
  """
  @spec undo(GenServer.server()) :: {:ok, map()} | {:error, :no_history}
  def undo(server) do
    GenServer.call(server, :undo)
  end

  @doc """
  Moves focus to the next or previous interactive control in the `:app` / `:split` view.
  """
  @spec move_control_focus(GenServer.server(), :next | :prev) :: {:ok, non_neg_integer()}
  def move_control_focus(server, direction) when direction in [:next, :prev] do
    GenServer.call(server, {:move_control_focus, direction})
  end

  @doc """
  Interacts with the currently focused control in the `:app` / `:split` view:
  - `:next_val` / `:prev_val` / `:toggle`: cycles a `Select` option or flips a `Toggle` boolean
  - `{:set_val, val}`: sets a `Field`, `Select`, or `Toggle` value
  - `:activate`: triggers a `Button` (interpolating `@ToAssistant` and recording/sending the action) or toggles a control
  """
  @spec interact_focused_control(GenServer.server(), term(), keyword()) :: {:ok, map()}
  def interact_focused_control(server, interaction \\ :activate, opts \\ []) do
    GenServer.call(server, {:interact_focused_control, interaction, opts}, 45_000)
  end

  @doc """
  Cycles the current app's TUI rendering engine (`fixed_80` ➔ `owl` ➔ `pure_ansi` ➔ `table_rex` ➔ `compact_ops`).
  """
  @spec cycle_renderer(GenServer.server()) :: {:ok, String.t()}
  def cycle_renderer(server) do
    GenServer.call(server, :cycle_renderer)
  end

  @doc """
  Switches the workspace to a different saved App Conversation (by ID or 1-based index).
  """
  @spec switch_app(GenServer.server(), String.t() | pos_integer()) ::
          {:ok, map()} | {:error, :not_found}
  def switch_app(server, id_or_index) do
    GenServer.call(server, {:switch_app, id_or_index})
  end

  @doc """
  Cycles to the next or previous saved App Conversation (switching both the Live UI and its Chat).
  """
  @spec cycle_app(GenServer.server(), :next | :prev) :: {:ok, map()}
  def cycle_app(server, direction \\ :next) when direction in [:next, :prev] do
    GenServer.call(server, {:cycle_app, direction})
  end

  @doc """
  Creates a new App Conversation and makes it active.
  """
  @spec create_new_app(GenServer.server(), String.t(), keyword()) :: {:ok, map()}
  def create_new_app(server, title, opts \\ []) do
    GenServer.call(server, {:create_new_app, title, opts})
  end

  @doc """
  Polls live `StreamSource` metrics for the active app and renders the Studio frame.
  Supports `:width`, `:height`, and `:fill_screen?` options for full-screen terminal rendering.
  """
  @spec render_frame(GenServer.server(), keyword()) :: [String.t()]
  def render_frame(server, opts \\ []) do
    GenServer.call(server, {:render_frame, opts})
  end

  @doc """
  Renders the Studio frame as a single newline-joined string.
  """
  @spec render_to_string(GenServer.server(), keyword()) :: String.t()
  def render_to_string(server, opts \\ []) do
    render_frame(server, opts) |> Enum.join("\n")
  end

  @doc """
  Returns the current Studio session state map.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Store.ensure_seeded!()
    apps = Store.list_apps()

    initial_app =
      case Keyword.get(opts, :app_id) do
        nil ->
          List.first(apps)

        app_id ->
          case Store.get_app(app_id) do
            {:ok, found} -> found
            _ -> List.first(apps)
          end
      end

    {:ok, live_pid} = LiveSession.start_link(auto_poll: false, write_tty: false)

    initial_tab = Keyword.get(opts, :initial_tab, :chat)
    initial_model = Keyword.get(opts, :model, OpenUITUI.Config.default_model())
    initial_effort = Keyword.get(opts, :reasoning_effort, nil)

    state =
      %__MODULE__{
        active_tab: initial_tab,
        prev_tab: initial_tab,
        model: initial_model,
        reasoning_effort: initial_effort,
        apps_list: apps,
        live_session: live_pid
      }
      |> load_app_into_session(initial_app)

    {:ok, state}
  end

  @impl true
  def handle_call(:toggle_chat_app_tab, _from, state) do
    next_tab =
      cond do
        state.active_tab == :split ->
          :app

        state.active_tab == :app and state.prev_tab == :split ->
          :split

        state.active_tab == :chat ->
          :app

        true ->
          :chat
      end

    status =
      case next_tab do
        :split ->
          "Split view (Chat + Live UI) — type to chat, [↑/↓ ←/→] for App controls, [Tab] Fullscreen UI"

        :app ->
          "Fullscreen UI view — [↑/↓] select control, [←/→] change value, [Enter] run, [Tab] back"

        :chat ->
          "Chat view — type a message + [Enter] to update UI, or press [Tab] for Live UI"
      end

    updated = %{state | active_tab: next_tab, prev_tab: state.active_tab, status_message: status}
    {:reply, {:ok, next_tab}, updated}
  end

  @impl true
  def handle_call({:switch_tab, tab}, _from, state) do
    updated = %{
      state
      | active_tab: tab,
        prev_tab: state.active_tab,
        apps_list: Store.list_apps(),
        status_message: "Viewing #{tab} view — press [Tab] to toggle view"
    }

    {:reply, {:ok, tab}, updated}
  end

  @impl true
  def handle_call({:update_input_buffer, op}, _from, state) do
    next_buf =
      case op do
        :backspace ->
          len = String.length(state.input_buffer)
          if len > 0, do: String.slice(state.input_buffer, 0, len - 1), else: ""

        {:append, ch} ->
          state.input_buffer <> to_string(ch)

        {:set, str} ->
          to_string(str)
      end

    {:reply, {:ok, next_buf}, %{state | input_buffer: next_buf}}
  end

  @impl true
  def handle_call({:stage_user_prompt, prompt}, _from, state) do
    trimmed = String.trim(prompt)
    model_name = OpenUITUI.Config.default_model()

    staged_app =
      state.current_app
      |> drop_pending_messages()
      |> append_message("user", trimmed, %{})
      |> append_message(
        "assistant",
        "⟳ Generating OpenUI UI update with #{model_name}... (1–2s)",
        %{"pending" => true}
      )

    next_state = %{
      state
      | current_app: staged_app,
        input_buffer: "",
        status_message: "⟳ Calling LiteLLM (#{model_name}) for: #{trimmed} ..."
    }

    {:reply, :ok, next_state}
  end

  @impl true
  def handle_call({:send_chat_message, prompt, opts}, from, state) do
    hot_reload_modified_modules()
    trimmed = String.trim(prompt)
    pre_staged? = Keyword.get(opts, :pre_staged?, false)

    app_with_user =
      if pre_staged? do
        drop_pending_messages(state.current_app)
      else
        state.current_app
        |> drop_pending_messages()
        |> append_message("user", trimmed, %{})
      end

    if Keyword.get(opts, :async_worker?, false) do
      start_async_chat_worker(state, app_with_user, trimmed, opts, from)
    else
      state_with_user = %{state | current_app: app_with_user, input_buffer: ""}

      try do
        case evolve_app_from_prompt(state_with_user, trimmed, opts) do
          {:ok, next_state, turn_info} ->
            {:reply, {:ok, turn_info}, %{next_state | input_buffer: ""}}

          {:error, reason} ->
            _ =
              CrashReporter.record_exception({:llm_error, reason}, [], %{
                app_id: state.current_app["id"],
                prompt: trimmed
              })

            err_app =
              app_with_user
              |> append_message("assistant", "⚠ Failed to generate UI: #{inspect(reason)}", %{})
              |> Store.save_app!()

            err_state = %{
              state_with_user
              | current_app: err_app,
                status_message: "LLM error: #{inspect(reason)}"
            }

            {:reply, {:error, reason}, err_state}
        end
      rescue
        e ->
          report_path =
            CrashReporter.record_exception(e, __STACKTRACE__, %{
              app_id: state.current_app["id"],
              prompt: trimmed
            })

          err_msg =
            "Recovered from error (#{Exception.message(e)}) — saved #{Path.basename(report_path)}"

          err_app =
            app_with_user
            |> append_message("assistant", "⚠ #{err_msg}", %{})
            |> Store.save_app!()

          {:reply, {:error, e},
           %{state_with_user | current_app: err_app, status_message: err_msg}}
      end
    end
  end

  @impl true
  def handle_call({:patch_app_code, patch_code, note}, _from, state) do
    next_state =
      apply_code_revision(state, patch_code, note, %{"cache_status" => "patch", "cost_usd" => 0.0})

    {:reply, {:ok, next_state.current_app}, next_state}
  end

  @impl true
  def handle_call(:undo, _from, state) do
    case Map.get(state.current_app, "history", []) do
      [prev | rest_history] ->
        restored_app =
          state.current_app
          |> Map.put("openui_code", prev["openui_code"])
          |> Map.put("revision", prev["revision"])
          |> Map.put("history", rest_history)
          |> append_message("assistant", "Reverted app UI to revision v#{prev["revision"]}.", %{
            "revision" => prev["revision"],
            "cache_status" => "undo"
          })
          |> Store.save_app!()

        next_state =
          state
          |> load_app_into_session(restored_app)
          |> Map.put(:status_message, "Undid last change — restored v#{prev["revision"]}")

        {:reply, {:ok, restored_app}, next_state}

      [] ->
        {:reply, {:error, :no_history}, %{state | status_message: "No previous revision to undo"}}
    end
  end

  @impl true
  def handle_call({:move_control_focus, direction}, _from, state) do
    count = length(state.controls)

    next_idx =
      cond do
        count == 0 ->
          0

        direction == :next ->
          rem(state.focused_control_idx + 1, count)

        direction == :prev ->
          rem(state.focused_control_idx - 1 + count, count)
      end

    ctrl_label =
      case Enum.at(state.controls, next_idx) do
        %{label: l, kind: k} -> "Focused #{k} \"#{l}\""
        _ -> "No controls"
      end

    {:reply, {:ok, next_idx},
     %{state | focused_control_idx: next_idx, status_message: ctrl_label}}
  end

  @impl true
  def handle_call({:interact_focused_control, interaction, opts}, _from, state) do
    case Enum.at(state.controls, state.focused_control_idx) do
      nil ->
        {:reply, {:ok, %{status: :no_controls}}, state}

      ctrl ->
        {result, next_state} = execute_control_interaction(state, ctrl, interaction, opts)
        {:reply, {:ok, result}, next_state}
    end
  end

  @impl true
  def handle_call(:cycle_renderer, _from, state) do
    cur = Map.get(state.current_app, "renderer", "fixed_80")
    idx = Enum.find_index(@renderers, &(&1 == cur)) || 0
    next_renderer = Enum.at(@renderers, rem(idx + 1, length(@renderers)))

    updated_app =
      state.current_app
      |> Map.put("renderer", next_renderer)
      |> Store.save_app!()

    next_state = %{
      state
      | current_app: updated_app,
        apps_list: Store.list_apps(),
        status_message: "Switched App Renderer to :#{next_renderer}"
    }

    {:reply, {:ok, next_renderer}, next_state}
  end

  @impl true
  def handle_call({:switch_app, id_or_index}, _from, state) do
    case Store.get_app(id_or_index) do
      {:ok, app} ->
        next_state =
          state
          |> load_app_into_session(app)
          |> Map.put(:apps_list, Store.list_apps())
          |> Map.put(
            :status_message,
            "Switched to UI + Chat \"#{app["title"]}\" (v#{app["revision"]})"
          )

        {:reply, {:ok, app}, next_state}

      {:error, :not_found} = err ->
        {:reply, err, %{state | status_message: "App '#{id_or_index}' not found"}}
    end
  end

  @impl true
  def handle_call({:cycle_app, direction}, _from, state) do
    apps = Store.list_apps()
    count = length(apps)

    if count == 0 do
      {:reply, {:ok, state.current_app}, state}
    else
      cur_id = state.current_app["id"]
      idx = Enum.find_index(apps, &(&1["id"] == cur_id)) || 0

      next_idx =
        case direction do
          :prev -> rem(idx - 1 + count, count)
          _ -> rem(idx + 1, count)
        end

      target_app = Enum.at(apps, next_idx)

      next_state =
        state
        |> load_app_into_session(target_app)
        |> Map.put(:apps_list, apps)
        |> Map.put(
          :status_message,
          "Switched to UI ##{next_idx + 1}: \"#{target_app["title"]}\" (v#{target_app["revision"]})"
        )

      {:reply, {:ok, target_app}, next_state}
    end
  end

  @impl true
  def handle_call({:create_new_app, title, opts}, _from, state) do
    app = Store.create_app!(title, opts)
    target_tab = if state.active_tab == :split, do: :split, else: :chat

    next_state =
      state
      |> load_app_into_session(app)
      |> Map.put(:apps_list, Store.list_apps())
      |> Map.put(:active_tab, target_tab)
      |> Map.put(:status_message, "Created new UI + Chat \"#{app["title"]}\"")

    {:reply, {:ok, app}, next_state}
  end

  @impl true
  def handle_call({:render_frame, opts}, _from, raw_state) do
    state = maybe_reload_disk_app(raw_state)
    ansi? = Keyword.get(opts, :ansi?, true)
    poll? = Keyword.get(opts, :poll?, true)
    outer_w = Keyword.get(opts, :width, 80)
    inner_w = max(outer_w - 4, 40)

    if poll? do
      LiveSession.poll_now(state.live_session)
    end

    live_state = LiveSession.get_state(state.live_session)
    controls = extract_controls(live_state.symbols, live_state.ui_state)
    live_info = extract_live_info(live_state)

    app_pane_width =
      if state.active_tab == :split and outer_w >= 100 do
        left_w = max(div(inner_w * 40, 100), 34)
        max(inner_w - left_w - 3, 40)
      else
        inner_w
      end

    rendered_app_lines =
      render_embedded_app(state.current_app, state.live_session, app_pane_width, ansi?)

    chrome_input = %{
      active_tab: state.active_tab,
      model: state.model,
      reasoning_effort: state.reasoning_effort,
      current_app: state.current_app,
      apps_list: state.apps_list,
      controls: controls,
      focused_control_idx: min(state.focused_control_idx, max(length(controls) - 1, 0)),
      current_ui_state: live_state.ui_state,
      live_info: live_info,
      rendered_app_lines: rendered_app_lines,
      input_buffer: state.input_buffer,
      status_message: state.status_message
    }

    lines = Chrome.render(chrome_input, opts)

    {:reply, lines, %{state | controls: controls, tick: state.tick + 1}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    live_state = LiveSession.get_state(state.live_session)

    {:reply,
     %{
       active_tab: state.active_tab,
       chat_in_flight?: state.chat_in_flight?,
       model: state.model,
       reasoning_effort: state.reasoning_effort,
       jido_agent: state.jido_agent,
       jido_tools: Agent.registered_tools(),
       current_app: state.current_app,
       apps_list: state.apps_list,
       controls: state.controls,
       focused_control_idx: state.focused_control_idx,
       input_buffer: state.input_buffer,
       ui_state: live_state.ui_state,
       live_info: extract_live_info(live_state),
       status_message: state.status_message
     }, state}
  end

  @impl true
  def handle_info({:chat_progress, step_text, extra_meta}, state) do
    updated_app =
      Map.update(state.current_app, "messages", [], fn msgs ->
        Enum.map(msgs, fn m ->
          if get_in(m, ["meta", "pending"]) == true do
            new_meta = Map.merge(m["meta"] || %{}, Map.put(extra_meta, "step", step_text))
            %{m | "text" => "⟳ " <> step_text, "meta" => new_meta}
          else
            m
          end
        end)
      end)

    {:noreply, %{state | current_app: updated_app, status_message: "⟳ " <> step_text}}
  end

  @impl true
  def handle_info(
        {:chat_worker_done, from, trimmed, app_with_user, outcome},
        state
      ) do
    state_with_user = %{state | current_app: app_with_user, chat_in_flight?: false}

    case outcome do
      {:create_new_app, intent_info, new_model, new_effort, {:ok, create_res}} ->
        # Remove the staged user message from the previous app so the previous app stays untouched
        clean_prev_app = drop_trailing_user_message(app_with_user, trimmed)

        {:ok, next_state, turn_info} =
          finalize_create_app_turn(
            %{
              state
              | current_app: clean_prev_app,
                model: new_model,
                reasoning_effort: new_effort
            },
            trimmed,
            new_model,
            new_effort,
            intent_info,
            create_res
          )

        GenServer.reply(from, {:ok, turn_info})
        {:noreply, %{next_state | chat_in_flight?: false}}

      {:model_switch, new_model, new_effort, intent_info} ->
        {:ok, next_state, turn_info} =
          finalize_model_switch_turn(
            state_with_user,
            trimmed,
            new_model,
            new_effort,
            intent_info
          )

        GenServer.reply(from, {:ok, turn_info})
        {:noreply, %{next_state | chat_in_flight?: false}}

      {:meta_qa, current_code, intent_info, new_model, new_effort, {:ok, llm_res}} ->
        {:ok, next_state, turn_info} =
          finalize_meta_question_turn(
            %{state_with_user | model: new_model, reasoning_effort: new_effort},
            trimmed,
            current_code,
            intent_info,
            llm_res
          )

        GenServer.reply(from, {:ok, turn_info})
        {:noreply, %{next_state | chat_in_flight?: false}}

      {:ui_build, current_code, intent_info, new_model, new_effort, {:ok, llm_res}} ->
        {:ok, next_state, turn_info} =
          finalize_ui_build_turn(
            %{state_with_user | model: new_model, reasoning_effort: new_effort},
            trimmed,
            current_code,
            intent_info,
            llm_res
          )

        GenServer.reply(from, {:ok, turn_info})
        {:noreply, %{next_state | chat_in_flight?: false}}

      {_mode, _current_code, _intent_info, _new_model, _new_effort, {:error, reason}} ->
        _ =
          CrashReporter.record_exception({:llm_error, reason}, [], %{
            app_id: state.current_app["id"],
            prompt: trimmed
          })

        err_app =
          app_with_user
          |> append_message("assistant", "Failed to complete chat turn: #{inspect(reason)}", %{})
          |> Store.save_app!()

        err_state = %{
          state_with_user
          | current_app: err_app,
            chat_in_flight?: false,
            status_message: "LLM error: #{inspect(reason)}"
        }

        GenServer.reply(from, {:error, reason})
        {:noreply, err_state}

      {:exception, e, stack} ->
        report_path =
          CrashReporter.record_exception(e, stack, %{
            app_id: state.current_app["id"],
            prompt: trimmed
          })

        err_msg =
          "Recovered from error (#{Exception.message(e)}) — saved #{Path.basename(report_path)}"

        err_app =
          app_with_user
          |> append_message("assistant", err_msg, %{})
          |> Store.save_app!()

        GenServer.reply(from, {:error, e})

        {:noreply,
         %{
           state_with_user
           | current_app: err_app,
             chat_in_flight?: false,
             status_message: err_msg
         }}
    end
  end

  defp start_async_chat_worker(state, app_with_user, trimmed, opts, from) do
    cur_model = Keyword.get(opts, :model, state.model || OpenUITUI.Config.default_model())
    cur_effort = Keyword.get(opts, :reasoning_effort, state.reasoning_effort)
    badge = OpenUITUI.Config.format_model_badge(cur_model, cur_effort)
    now_ms = System.monotonic_time(:millisecond)

    app_with_pending =
      append_message(
        app_with_user,
        "assistant",
        "⟳ Step 1/2: Jev classifying request & model (#{badge})...",
        %{
          "pending" => true,
          "started_at_ms" => now_ms,
          "model" => badge,
          "step" => "Step 1/2: Jev classifying request & model (#{badge})..."
        }
      )

    working_state = %{
      state
      | current_app: app_with_pending,
        chat_in_flight?: true,
        input_buffer: "",
        status_message: "⟳ Step 1/2: Classifying prompt intent with TypeSafe Jev..."
    }

    current_code = Map.get(app_with_user, "openui_code", "") |> String.trim()
    live_state = LiveSession.get_state(state.live_session)
    live_info = extract_live_info(live_state)
    app_title = app_with_user["title"]
    app_rev = app_with_user["revision"] || 1
    server_pid = self()

    jido_agent =
      state.jido_agent || Agent.new_for_app(app_with_user, cur_model, cur_effort)

    spawn_link(fn ->
      outcome =
        try do
          {:ok, agent_after_classify, classify_res} =
            Agent.classify(jido_agent, %{
              prompt: trimmed,
              app_title: app_title,
              has_live_stream: live_info.active?,
              statement_count: count_statements(current_code),
              current_model: cur_model,
              current_effort: cur_effort,
              llm_opts: opts
            })

          eff_intent = classify_res.effective_intent
          new_model = classify_res.target_model
          new_effort = classify_res.reasoning_effort
          new_badge = classify_res.model_badge
          intent_info = classify_res.intent_info

          call_opts =
            opts
            |> Keyword.put(:model, new_model)
            |> Keyword.put(:reasoning_effort, new_effort)

          cond do
            eff_intent == "switch_model" ->
              {:model_switch, new_model, new_effort, intent_info}

            eff_intent == "create_new_app" ->
              step_txt =
                "Step 2/2: Jido.CreateApp creating new App + fresh Chat (#{new_badge})..."

              send(
                server_pid,
                {:chat_progress, step_txt,
                 %{
                   "jev_intent" => eff_intent,
                   "jev_topic" => classify_res.topic,
                   "model" => new_badge
                 }}
              )

              create_res =
                case Agent.create_app(agent_after_classify, %{
                       prompt: trimmed,
                       next_app_number: length(state.apps_list) + 1,
                       model: new_model,
                       reasoning_effort: new_effort,
                       intent_info: intent_info,
                       llm_opts: call_opts
                     }) do
                  {:ok, _agent, res} -> {:ok, res}
                  {:error, reason} -> {:error, reason}
                end

              {:create_new_app, intent_info, new_model, new_effort, create_res}

            eff_intent == "ask_question_or_meta" and current_code != "" ->
              step_txt =
                "Step 2/2: Jido.AnswerQuestion (#{new_badge}) — keeping UI v#{app_rev}..."

              send(
                server_pid,
                {:chat_progress, step_txt,
                 %{
                   "jev_intent" => eff_intent,
                   "jev_topic" => classify_res.topic,
                   "model" => new_badge
                 }}
              )

              studio_ctx = %{
                title: app_title,
                revision: app_rev,
                live_sources: live_info.sources,
                live_tick: live_info.tick,
                live_bindings: live_info.live_bindings,
                ui_state: live_state.ui_state,
                openui_code: current_code
              }

              llm_res =
                case Agent.answer_question(agent_after_classify, %{
                       prompt: trimmed,
                       studio_ctx: studio_ctx,
                       model: new_model,
                       reasoning_effort: new_effort,
                       intent_info: intent_info,
                       llm_opts: call_opts
                     }) do
                  {:ok, _agent, %{llm_res: res}} -> {:ok, res}
                  {:error, reason} -> {:error, reason}
                end

              {:meta_qa, current_code, intent_info, new_model, new_effort, llm_res}

            true ->
              step_txt = "Step 2/2: Jido.EvolveUI generating OpenUI AST with #{new_badge}..."

              send(
                server_pid,
                {:chat_progress, step_txt,
                 %{
                   "jev_intent" => eff_intent,
                   "jev_topic" => classify_res.topic,
                   "model" => new_badge
                 }}
              )

              contextual_prompt =
                build_contextual_ui_prompt(
                  app_title,
                  app_rev,
                  current_code,
                  live_state,
                  live_info,
                  trimmed
                )

              llm_res =
                case Agent.evolve_ui(agent_after_classify, %{
                       contextual_prompt: contextual_prompt,
                       model: new_model,
                       reasoning_effort: new_effort,
                       intent_info: intent_info,
                       llm_opts: call_opts
                     }) do
                  {:ok, _agent, %{llm_res: res}} -> {:ok, res}
                  {:error, reason} -> {:error, reason}
                end

              {:ui_build, current_code, intent_info, new_model, new_effort, llm_res}
          end
        rescue
          e -> {:exception, e, __STACKTRACE__}
        end

      send(server_pid, {:chat_worker_done, from, trimmed, app_with_user, outcome})
    end)

    {:noreply, working_state}
  end

  # ── Internal Helpers: Loading & Rendering App in LiveSession ─────────────

  defp load_app_into_session(state, app) do
    {:ok, new_live_pid} = LiveSession.start_link(auto_poll: false, write_tty: false)

    if state.live_session && Process.alive?(state.live_session) do
      GenServer.stop(state.live_session, :normal)
    end

    code = Map.get(app, "openui_code", "")
    saved_ui_state = Map.get(app, "ui_state", %{})
    saved_model = Map.get(app, "model") || state.model || OpenUITUI.Config.default_model()
    saved_effort = Map.get(app, "reasoning_effort", state.reasoning_effort)
    jido_agent = Agent.new_for_app(app, saved_model, saved_effort)

    :ok = LiveSession.load_openui(new_live_pid, code)

    Enum.each(saved_ui_state, fn {k, v} ->
      LiveSession.put_ui_state(new_live_pid, k, v)
    end)

    LiveSession.poll_now(new_live_pid)
    live_state = LiveSession.get_state(new_live_pid)
    controls = extract_controls(live_state.symbols, live_state.ui_state)

    %{
      state
      | current_app: app,
        model: saved_model,
        reasoning_effort: saved_effort,
        jido_agent: jido_agent,
        live_session: new_live_pid,
        controls: controls,
        focused_control_idx: 0
    }
  end

  defp render_embedded_app(app, live_session, pane_width, ansi?) do
    renderer = Map.get(app, "renderer", "fixed_80")
    code = Map.get(app, "openui_code", "")

    case renderer do
      "fixed_80" ->
        LiveSession.render_lines(live_session,
          ansi?: ansi?,
          width: pane_width,
          outer_width: pane_width,
          frameless?: true
        )

      other_renderer ->
        r_atom =
          case other_renderer do
            "owl" -> :owl
            "pure_ansi" -> :pure_ansi
            "table_rex" -> :table_rex
            "compact_ops" -> :compact_ops
            _ -> :fixed_80
          end

        rendered =
          try do
            OpenUITUI.render(code, r_atom)
          rescue
            _ -> "(empty OpenUI root)"
          end

        if rendered in ["", "(empty OpenUI root)"] do
          LiveSession.render_lines(live_session,
            ansi?: ansi?,
            width: pane_width,
            outer_width: pane_width,
            frameless?: true
          )
        else
          clean =
            if ansi? do
              rendered
            else
              String.replace(rendered, ~r/\e\[[0-9;]*m/, "")
            end

          String.split(clean, "\n")
        end
    end
  end

  # ── Internal Helpers: Conversational App Evolution ───────────────────────

  defp evolve_app_from_prompt(state, prompt, opts) do
    current_code = Map.get(state.current_app, "openui_code", "") |> String.trim()
    live_state = LiveSession.get_state(state.live_session)
    live_info = extract_live_info(live_state)
    cur_model = Keyword.get(opts, :model, state.model || OpenUITUI.Config.default_model())
    cur_effort = Keyword.get(opts, :reasoning_effort, state.reasoning_effort)

    jido_agent =
      state.jido_agent || Agent.new_for_app(state.current_app, cur_model, cur_effort)

    {:ok, agent_after_classify, classify_res} =
      Agent.classify(jido_agent, %{
        prompt: prompt,
        app_title: state.current_app["title"],
        has_live_stream: live_info.active?,
        statement_count: count_statements(current_code),
        current_model: cur_model,
        current_effort: cur_effort,
        llm_opts: opts
      })

    eff_intent = classify_res.effective_intent
    new_model = classify_res.target_model
    new_effort = classify_res.reasoning_effort
    intent_info = classify_res.intent_info

    state_with_model = %{
      state
      | model: new_model,
        reasoning_effort: new_effort,
        jido_agent: agent_after_classify
    }

    call_opts =
      opts
      |> Keyword.put(:model, new_model)
      |> Keyword.put(:reasoning_effort, new_effort)

    cond do
      eff_intent == "switch_model" ->
        finalize_model_switch_turn(state_with_model, prompt, new_model, new_effort, intent_info)

      eff_intent == "create_new_app" ->
        clean_prev_app = drop_trailing_user_message(state.current_app, prompt)

        case Agent.create_app(agent_after_classify, %{
               prompt: prompt,
               next_app_number: length(state.apps_list) + 1,
               model: new_model,
               reasoning_effort: new_effort,
               intent_info: intent_info,
               llm_opts: call_opts
             }) do
          {:ok, _updated_agent, create_res} ->
            finalize_create_app_turn(
              %{state_with_model | current_app: clean_prev_app},
              prompt,
              new_model,
              new_effort,
              intent_info,
              create_res
            )

          {:error, reason} ->
            {:error, reason}
        end

      eff_intent == "ask_question_or_meta" and current_code != "" ->
        answer_meta_question_in_chat(
          state_with_model,
          prompt,
          current_code,
          live_state,
          live_info,
          intent_info,
          call_opts
        )

      true ->
        build_or_update_ui_from_prompt(
          state_with_model,
          prompt,
          current_code,
          live_state,
          live_info,
          intent_info,
          call_opts
        )
    end
  end

  defp finalize_create_app_turn(state, prompt, new_model, new_effort, intent_info, create_res) do
    # Ensure the previous app on disk does not contain the "make new app" prompt
    if is_map(state.current_app) and is_binary(state.current_app["id"]) do
      Store.save_app!(state.current_app, preserve_timestamp?: true)
    end

    badge = create_res.model_badge

    {final_title, final_code, final_ui_state, assistant_note, llm_res} =
      case create_res.mode do
        :generated ->
          res = create_res.llm_res
          %{prose: prose, code: extracted_code} = OpenUILang.demux(res.content)
          cand = if String.trim(extracted_code) != "", do: extracted_code, else: res.content
          valid_code = ensure_valid_root(cand, "", create_res.title, prompt)
          extracted_title = extract_title(valid_code, create_res.title)

          note =
            if String.trim(prose) != "" do
              String.trim(prose)
            else
              "Created new App \"#{extracted_title}\" with its own Chat workspace."
            end

          {extracted_title, valid_code, %{}, note, res}

        _ ->
          {
            create_res.title,
            create_res.openui_code,
            create_res.ui_state || %{},
            create_res.assistant_note,
            nil
          }
      end

    prompt_tok =
      Map.get(intent_info, :prompt_tokens, 0) +
        if(llm_res, do: Map.get(llm_res, :prompt_tokens, 0), else: 0)

    comp_tok =
      Map.get(intent_info, :completion_tokens, 0) +
        if(llm_res, do: Map.get(llm_res, :completion_tokens, 0), else: 0)

    total_tok = prompt_tok + comp_tok

    dur_ms =
      Map.get(intent_info, :duration_ms, 0) +
        if(llm_res, do: Map.get(llm_res, :duration_ms, 0), else: 0)

    eff_cost = if(llm_res, do: Map.get(llm_res, :effective_cost_usd, 0.0), else: 0.0)

    raw_cost =
      Map.get(intent_info, :raw_cost_usd, 0.0) +
        if(llm_res, do: Map.get(llm_res, :raw_cost_usd, 0.0), else: 0.0)

    cache_str =
      to_string(
        if(llm_res, do: llm_res.cache_status, else: Map.get(intent_info, :cache_status, "miss"))
      )

    meta = %{
      "revision" => 1,
      "statement_count" => count_statements(final_code),
      "cache_status" => cache_str,
      "prompt_tokens" => prompt_tok,
      "completion_tokens" => comp_tok,
      "total_tokens" => total_tok,
      "cost_usd" => eff_cost,
      "raw_cost_usd" => raw_cost,
      "duration_ms" => dur_ms,
      "model" => badge,
      "jev_intent" => "create_new_app",
      "jev_topic" => Map.get(intent_info, :topic, "ui_code_and_components")
    }

    created_app =
      Store.create_app!(final_title, openui_code: final_code)
      |> Map.put("model", new_model)
      |> Map.put("reasoning_effort", new_effort)
      |> Map.put("ui_state", final_ui_state)
      |> Map.put("messages", [])
      |> append_message("user", prompt, %{})
      |> append_message("assistant", assistant_note, meta)
      |> Store.save_app!()

    apps = Store.list_apps()
    new_idx = (Enum.find_index(apps, &(&1["id"] == created_app["id"])) || length(apps) - 1) + 1

    next_state =
      state
      |> Map.put(:model, new_model)
      |> Map.put(:reasoning_effort, new_effort)
      |> load_app_into_session(created_app)
      |> Map.put(:apps_list, apps)
      |> Map.put(
        :status_message,
        "Created new App ##{new_idx}: \"#{created_app["title"]}\" (v1) with its own Chat"
      )

    turn_info = %{
      prompt: prompt,
      jev_intent: "create_new_app",
      jev_topic: Map.get(intent_info, :topic, "ui_code_and_components"),
      model: new_model,
      reasoning_effort: new_effort,
      assistant_note: assistant_note,
      openui_code: final_code,
      revision: 1,
      app_id: created_app["id"],
      cache_status: cache_str,
      prompt_tokens: prompt_tok,
      completion_tokens: comp_tok,
      total_tokens: total_tok,
      effective_cost_usd: eff_cost
    }

    {:ok, next_state, turn_info}
  end

  defp drop_trailing_user_message(app, prompt) when is_map(app) do
    clean_app = drop_pending_messages(app)
    msgs = Map.get(clean_app, "messages", [])

    updated_msgs =
      case List.last(msgs) do
        %{"role" => "user", "text" => t} when t == prompt ->
          Enum.drop(msgs, -1)

        _ ->
          msgs
      end

    Map.put(clean_app, "messages", updated_msgs)
  end

  defp finalize_model_switch_turn(state, prompt, new_model, new_effort, intent_info) do
    rev = state.current_app["revision"] || 1
    current_code = Map.get(state.current_app, "openui_code", "")

    jido_agent =
      state.jido_agent || Agent.new_for_app(state.current_app, new_model, new_effort)

    {:ok, updated_agent, switch_res} =
      Agent.switch_model(jido_agent, %{
        prompt: prompt,
        target_model: new_model,
        reasoning_effort: new_effort,
        revision: rev,
        statement_count: count_statements(current_code),
        intent_info: intent_info
      })

    badge = switch_res.model_badge
    answer_text = switch_res.answer_text
    meta = switch_res.meta

    updated_app =
      state.current_app
      |> Map.put("model", new_model)
      |> Map.put("reasoning_effort", new_effort)
      |> append_message("assistant", answer_text, meta)
      |> Store.save_app!()

    next_state = %{
      state
      | model: new_model,
        reasoning_effort: new_effort,
        jido_agent: updated_agent,
        current_app: updated_app,
        apps_list: Store.list_apps(),
        status_message: "Switched active model to #{badge} via Jido"
    }

    turn_info = %{
      prompt: prompt,
      jev_intent: "switch_model",
      jev_topic: "studio_usage_and_meta",
      model: new_model,
      reasoning_effort: new_effort,
      assistant_note: answer_text,
      openui_code: current_code,
      revision: rev,
      cache_status: to_string(Map.get(intent_info, :cache_status, "miss")),
      prompt_tokens: switch_res.prompt_tokens,
      completion_tokens: switch_res.completion_tokens,
      total_tokens: switch_res.total_tokens,
      effective_cost_usd: 0.0
    }

    {:ok, next_state, turn_info}
  end

  defp answer_meta_question_in_chat(
         state,
         prompt,
         current_code,
         live_state,
         live_info,
         intent_info,
         opts
       ) do
    studio_ctx = %{
      title: state.current_app["title"],
      revision: state.current_app["revision"] || 1,
      live_sources: live_info.sources,
      live_tick: live_info.tick,
      live_bindings: live_info.live_bindings,
      ui_state: live_state.ui_state,
      openui_code: current_code
    }

    jido_agent =
      state.jido_agent ||
        Agent.new_for_app(state.current_app, state.model, state.reasoning_effort)

    case Agent.answer_question(jido_agent, %{
           prompt: prompt,
           studio_ctx: studio_ctx,
           model: state.model,
           reasoning_effort: state.reasoning_effort,
           intent_info: intent_info,
           llm_opts: opts
         }) do
      {:ok, updated_agent, %{llm_res: llm_res}} ->
        finalize_meta_question_turn(
          %{state | jido_agent: updated_agent},
          prompt,
          current_code,
          intent_info,
          llm_res
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_meta_question_turn(state, prompt, current_code, intent_info, llm_res) do
    answer_text = String.trim(llm_res.content)
    cache_str = to_string(llm_res.cache_status)
    rev = state.current_app["revision"] || 1
    prompt_tok = Map.get(llm_res, :prompt_tokens, 0) + Map.get(intent_info, :prompt_tokens, 0)

    comp_tok =
      Map.get(llm_res, :completion_tokens, 0) + Map.get(intent_info, :completion_tokens, 0)

    total_tok = prompt_tok + comp_tok
    dur_ms = Map.get(llm_res, :duration_ms, 0) + Map.get(intent_info, :duration_ms, 0)
    raw_cost = Map.get(llm_res, :raw_cost_usd, llm_res.effective_cost_usd)

    badge =
      OpenUITUI.Config.format_model_badge(
        Map.get(llm_res, :model, state.model),
        state.reasoning_effort
      )

    meta = %{
      "revision" => rev,
      "statement_count" => count_statements(current_code),
      "cache_status" => cache_str,
      "prompt_tokens" => prompt_tok,
      "completion_tokens" => comp_tok,
      "total_tokens" => total_tok,
      "cost_usd" => llm_res.effective_cost_usd,
      "raw_cost_usd" => raw_cost,
      "duration_ms" => dur_ms,
      "model" => badge,
      "jev_intent" => "ask_question_or_meta",
      "jev_topic" => intent_info.topic,
      "jido_actions" => [
        %{
          "name" => "Jido.ClassifyIntent",
          "detail" => "ask_question_or_meta (#{intent_info.topic})"
        },
        %{
          "name" => "Jido.AnswerQuestion",
          "detail" => "UI v#{rev} unchanged • #{badge}"
        }
      ]
    }

    updated_app =
      state.current_app
      |> Map.put("model", state.model)
      |> Map.put("reasoning_effort", state.reasoning_effort)
      |> append_message("assistant", answer_text, meta)
      |> Store.save_app!()

    next_state = %{
      state
      | current_app: updated_app,
        apps_list: Store.list_apps(),
        status_message:
          "Answered in Chat [#{badge}] (#{total_tok} tok • $#{:erlang.float_to_binary(llm_res.effective_cost_usd * 1.0, decimals: 4)}) — UI v#{rev} kept"
    }

    turn_info = %{
      prompt: prompt,
      jev_intent: intent_info.intent,
      jev_topic: intent_info.topic,
      model: state.model,
      reasoning_effort: state.reasoning_effort,
      assistant_note: answer_text,
      openui_code: current_code,
      revision: rev,
      cache_status: cache_str,
      prompt_tokens: prompt_tok,
      completion_tokens: comp_tok,
      total_tokens: total_tok,
      effective_cost_usd: llm_res.effective_cost_usd
    }

    {:ok, next_state, turn_info}
  end

  defp build_or_update_ui_from_prompt(
         state,
         prompt,
         current_code,
         live_state,
         live_info,
         intent_info,
         opts
       ) do
    contextual_prompt =
      build_contextual_ui_prompt(
        state.current_app["title"],
        state.current_app["revision"],
        current_code,
        live_state,
        live_info,
        prompt
      )

    jido_agent =
      state.jido_agent ||
        Agent.new_for_app(state.current_app, state.model, state.reasoning_effort)

    case Agent.evolve_ui(jido_agent, %{
           contextual_prompt: contextual_prompt,
           model: state.model,
           reasoning_effort: state.reasoning_effort,
           intent_info: intent_info,
           llm_opts: opts
         }) do
      {:ok, updated_agent, %{llm_res: llm_res}} ->
        finalize_ui_build_turn(
          %{state | jido_agent: updated_agent},
          prompt,
          current_code,
          intent_info,
          llm_res
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_contextual_ui_prompt(title, revision, current_code, live_state, live_info, prompt) do
    if current_code == "" do
      prompt
    else
      live_status_str =
        if live_info.active? do
          "ACTIVE 1Hz StreamSources: #{Enum.join(live_info.sources, ", ")}"
        else
          "NONE (static UI — add StreamSource if the user wants live/real-time/updating metrics!)"
        end

      # Include actual polled live bindings so the LLM never hallucinates slab sizes or metrics
      live_snapshot =
        live_info.live_bindings
        |> Map.take([
          "$live_diagnostic_summary",
          "$live_slab_rows",
          "$live_slab_ids",
          "$live_service_cache_kv",
          "$live_memory_net_kv",
          "$live_ops_kv",
          "$llm_calls_kpi",
          "$llm_tokens_kpi",
          "$llm_cache_kpi",
          "$llm_spend_kpi",
          "$llm_spend_kv",
          "$llm_pipeline_kv",
          "$llm_model_rows",
          "$llm_model_ids",
          "$llm_diagnostic_summary"
        ])
        |> Jason.encode!()

      """
      Existing OpenUI App ("#{title}", v#{revision}):
      ```openui
      #{current_code}
      ```
      Current live stream status: #{live_status_str}
      Current reactive $state values: #{Jason.encode!(live_state.ui_state)}
      Current real-time parsed metrics snapshot (from OpenUITUI.Memcached.Parser): #{live_snapshot}

      Layout & Visual Quality Rules:
      - NEVER invent or hallucinate static metric numbers (like fake 64KB chunk sizes) when real `$live_*` bindings or parsed slab metrics are present above! Always use the real numbers from the snapshot or bind directly to `$live_*` variables.
      - Group operational KV sections inside bordered `Panel(title, [KV(...)], tone)` cards or a 2-column `Row([Panel("1-2. Service & Cache Performance", [KV($live_service_cache_kv)], "info"), Panel("3-4. Memory Health & Network I/O", [KV($live_memory_net_kv)], "ok")])` so the dashboard has crisp visual hierarchy.

      User request to update or evolve this app:
      #{prompt}

      Write 1 short sentence explaining what you updated, then return the complete updated OpenUI Lang program in a ```openui code block (`root = ...` and all component/stream/form statements).
      """
    end
  end

  defp finalize_ui_build_turn(state, prompt, current_code, intent_info, llm_res) do
    %{prose: prose, code: extracted_code} = OpenUILang.demux(llm_res.content)

    candidate_code =
      if String.trim(extracted_code) != "", do: extracted_code, else: llm_res.content

    raw_merged = smart_merge_openui(current_code, candidate_code)

    merged_code =
      ensure_valid_root(raw_merged, current_code, state.current_app["title"], prompt)

    cache_str = to_string(llm_res.cache_status)
    old_rev = state.current_app["revision"] || 1
    new_rev = old_rev + 1
    new_title = extract_title(merged_code, state.current_app["title"])
    comp_summary = summarize_components(merged_code)

    lead_line =
      if String.trim(prose) != "" do
        String.trim(prose)
      else
        "Updated \"#{new_title}\" (#{comp_summary}) [cache=#{cache_str}]."
      end

    prompt_tok = Map.get(llm_res, :prompt_tokens, 0) + Map.get(intent_info, :prompt_tokens, 0)

    comp_tok =
      Map.get(llm_res, :completion_tokens, 0) + Map.get(intent_info, :completion_tokens, 0)

    total_tok = prompt_tok + comp_tok
    dur_ms = Map.get(llm_res, :duration_ms, 0) + Map.get(intent_info, :duration_ms, 0)
    raw_cost = Map.get(llm_res, :raw_cost_usd, llm_res.effective_cost_usd)

    badge =
      OpenUITUI.Config.format_model_badge(
        Map.get(llm_res, :model, state.model),
        state.reasoning_effort
      )

    meta = %{
      "revision" => new_rev,
      "statement_count" => count_statements(merged_code),
      "cache_status" => cache_str,
      "prompt_tokens" => prompt_tok,
      "completion_tokens" => comp_tok,
      "total_tokens" => total_tok,
      "cost_usd" => llm_res.effective_cost_usd,
      "raw_cost_usd" => raw_cost,
      "duration_ms" => dur_ms,
      "model" => badge,
      "jev_intent" => intent_info.intent,
      "jev_topic" => intent_info.topic
    }

    next_state =
      state
      |> apply_code_revision(merged_code, lead_line, meta, append_diff?: true)

    last_msg = List.last(next_state.current_app["messages"] || [])
    final_note = if last_msg, do: last_msg["text"], else: lead_line

    turn_info = %{
      prompt: prompt,
      jev_intent: intent_info.intent,
      jev_topic: intent_info.topic,
      model: state.model,
      reasoning_effort: state.reasoning_effort,
      assistant_note: final_note,
      openui_code: merged_code,
      revision: next_state.current_app["revision"],
      cache_status: cache_str,
      prompt_tokens: prompt_tok,
      completion_tokens: comp_tok,
      total_tokens: total_tok,
      effective_cost_usd: llm_res.effective_cost_usd
    }

    {:ok, next_state, turn_info}
  end

  defp apply_code_revision(state, new_code, assistant_note, meta, opts \\ []) do
    old_app = state.current_app
    old_rev = Map.get(old_app, "revision", 1)
    old_code = Map.get(old_app, "openui_code", "")

    merged_code = smart_merge_openui(old_code, new_code)

    new_rev = old_rev + 1
    new_title = extract_title(merged_code, old_app["title"])

    history_entry = %{
      "revision" => old_rev,
      "openui_code" => old_code,
      "timestamp" => Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    }

    updated_history = Enum.take([history_entry | Map.get(old_app, "history", [])], 15)

    # Start a clean LiveSession for the updated code while preserving existing ui_state
    saved_ui = LiveSession.get_state(state.live_session).ui_state
    {:ok, fresh_live_pid} = LiveSession.start_link(auto_poll: false, write_tty: false)

    if state.live_session && Process.alive?(state.live_session) do
      GenServer.stop(state.live_session, :normal)
    end

    :ok = LiveSession.load_openui(fresh_live_pid, merged_code)

    Enum.each(saved_ui, fn {k, v} ->
      LiveSession.put_ui_state(fresh_live_pid, k, v)
    end)

    LiveSession.poll_now(fresh_live_pid)
    live_state = LiveSession.get_state(fresh_live_pid)
    controls = extract_controls(live_state.symbols, live_state.ui_state)
    live_info = extract_live_info(live_state)

    final_assistant_note =
      if Keyword.get(opts, :append_diff?, false) do
        diff_block =
          summarize_ui_diff(old_code, merged_code, old_rev, new_rev, live_info, controls)

        assistant_note <> "\n" <> diff_block
      else
        assistant_note
      end

    updated_meta =
      meta
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("revision", new_rev)
      |> Map.put_new("statement_count", count_statements(merged_code))
      |> Map.put("live_active", live_info.active?)
      |> Map.put("control_count", length(controls))

    updated_app =
      old_app
      |> Map.put("title", new_title)
      |> Map.put("revision", new_rev)
      |> Map.put("model", state.model)
      |> Map.put("reasoning_effort", state.reasoning_effort)
      |> Map.put("openui_code", String.trim(merged_code))
      |> Map.put("ui_state", live_state.ui_state)
      |> Map.put("history", updated_history)
      |> append_message("assistant", final_assistant_note, updated_meta)
      |> Store.save_app!()

    live_badge =
      if live_info.active?,
        do: " • ● LIVE 1Hz (#{Enum.join(live_info.sources, ", ")})",
        else: ""

    %{
      state
      | current_app: updated_app,
        live_session: fresh_live_pid,
        apps_list: Store.list_apps(),
        controls: controls,
        focused_control_idx: min(state.focused_control_idx, max(length(controls) - 1, 0)),
        status_message: "Updated UI to v#{new_rev} (#{length(controls)} controls#{live_badge})"
    }
  end

  defp extract_live_info(live_state) do
    mem_src =
      case live_state.polling_target do
        {host, port} -> ["memcached@#{host}:#{port}"]
        _ -> []
      end

    mem_pipeline =
      case live_state.polling_target do
        {host, port} ->
          [
            "StreamSource(\"memcached\", \"#{host}:#{port}\", 1000) ➔ OpenUITUI.Memcached.Probe (:gen_tcp ASCII STAT parser, 0 LLM tokens)"
          ]

        _ ->
          []
      end

    gen_srcs =
      live_state.generic_sources
      |> Map.values()
      |> Enum.map(fn s -> "#{s.id}(#{s.transport}:#{s.target})" end)
      |> Enum.sort()

    gen_pipelines =
      live_state.generic_sources
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn s ->
        "StreamSource(#{inspect(s.id)}, #{inspect(s.transport)}, #{inspect(s.target)}, #{inspect(s.format)}, #{s.interval_ms}) ➔ OpenUITUI.SourceNormalizer + BindingEngine (0 LLM tokens)"
      end)

    llm_src =
      if Map.get(live_state, :llm_telemetry?, false) do
        ["openui_telemetry(events.jsonl+SpendGuard)"]
      else
        []
      end

    llm_pipeline =
      if Map.get(live_state, :llm_telemetry?, false) do
        [
          "StreamSource(\"openui_telemetry\", \"local\", 1000) ➔ OpenUITUI.LLMTelemetry.Parser (events.jsonl + SpendGuard, 0 LLM tokens)"
        ]
      else
        []
      end

    live_bindings =
      live_state.symbols
      |> Enum.filter(fn {k, v} ->
        String.starts_with?(k, "$") and
          (is_binary(v) or is_number(v) or is_boolean(v) or is_list(v) or is_map(v))
      end)
      |> Map.new()

    sources = mem_src ++ llm_src ++ gen_srcs

    %{
      active?: sources != [],
      tick: live_state.tick,
      sources: sources,
      pipelines: mem_pipeline ++ llm_pipeline ++ gen_pipelines,
      live_bindings: live_bindings
    }
  end

  defp smart_merge_openui(old_code, new_code) do
    old_trimmed = String.trim(old_code || "")
    new_trimmed = String.trim(new_code || "")

    if old_trimmed == "" do
      new_trimmed
    else
      OpenUILang.merge_statements(old_trimmed, new_trimmed)
    end
  end

  defp summarize_ui_diff(old_code, merged_code, old_rev, new_rev, live_info, controls) do
    old_syms = OpenUILang.parse_symbols(old_code || "")
    new_syms = OpenUILang.parse_symbols(merged_code || "")

    old_keys = Map.keys(old_syms) |> Enum.reject(&String.starts_with?(&1, "$live_"))
    new_keys = Map.keys(new_syms) |> Enum.reject(&String.starts_with?(&1, "$live_"))

    added = new_keys -- old_keys
    removed = old_keys -- new_keys

    updated =
      Enum.filter(new_keys -- added, fn k ->
        Map.get(old_syms, k) != Map.get(new_syms, k)
      end)

    parts =
      [
        if(added != [],
          do: "+#{length(added)} added (#{Enum.join(Enum.take(added, 4), ", ")})",
          else: nil
        ),
        if(updated != [],
          do: "~#{length(updated)} updated (#{Enum.join(Enum.take(updated, 4), ", ")})",
          else: nil
        ),
        if(removed != [],
          do: "-#{length(removed)} pruned",
          else: nil
        )
      ]
      |> Enum.reject(&is_nil/1)

    stmt_summary =
      if parts == [],
        do: "#{length(new_keys)} statements active",
        else: Enum.join(parts, ", ")

    live_line =
      if live_info.active? do
        "• Live Stream: ● LIVE 1Hz (#{Enum.join(live_info.sources, ", ")})"
      else
        "• Live Stream: Static snapshot (ask \"make it live\" to attach 1Hz StreamSource)"
      end

    ctrl_line =
      if controls == [] do
        "• Controls: none (ask \"make it interactive\" to add Form/Select/Button)"
      else
        ctrl_names =
          controls
          |> Enum.take(4)
          |> Enum.map_join(", ", fn c -> "#{c.kind} \"#{c.label}\"" end)

        "• Controls: #{length(controls)} active (#{ctrl_names})"
      end

    """
    Δ UI Changes (v#{old_rev} ➔ v#{new_rev}):
      #{live_line}
      • Statements: #{stmt_summary}
      #{ctrl_line}\
    """
  end

  # ── Internal Helpers: Recursive Interactive Widget Discovery ─────────────

  defp extract_controls(symbols, ui_state) when is_map(symbols) do
    raw =
      case Map.get(symbols, "root") do
        nil ->
          symbols
          |> Enum.flat_map(fn {id, ast} ->
            collect_controls_from_node(id, ast, symbols, ui_state, MapSet.new([id]))
          end)

        root_ast ->
          collect_controls_from_node("root", root_ast, symbols, ui_state, MapSet.new(["root"]))
      end

    raw
    |> Enum.uniq_by(&{&1.kind, &1.label, Map.get(&1, :var, &1.id)})
  end

  defp collect_controls_from_node(_id, {:ref, ref_name}, symbols, ui_state, visited) do
    if MapSet.member?(visited, ref_name) do
      []
    else
      case Map.get(symbols, ref_name) do
        nil ->
          []

        target_ast ->
          collect_controls_from_node(
            ref_name,
            target_ast,
            symbols,
            ui_state,
            MapSet.put(visited, ref_name)
          )
      end
    end
  end

  defp collect_controls_from_node(
         id,
         {"Select", [label, var_ast, opts_ast | _]},
         symbols,
         ui_state,
         _visited
       ) do
    var_name = extract_state_var(var_ast)
    options = resolve_select_options(opts_ast, symbols, ui_state)

    [
      %{
        id: id,
        kind: "Select",
        order: 0,
        label: safe_label(label),
        var: var_name,
        options: options
      }
    ]
  end

  defp collect_controls_from_node(
         id,
         {"Toggle", [label, var_ast | _]},
         _symbols,
         _ui_state,
         _visited
       ) do
    var_name = extract_state_var(var_ast)
    [%{id: id, kind: "Toggle", order: 0, label: safe_label(label), var: var_name}]
  end

  defp collect_controls_from_node(
         id,
         {"Field", [label, var_ast | rest]},
         _symbols,
         _ui_state,
         _visited
       ) do
    var_name = extract_state_var(var_ast)
    ph = List.first(rest) || ""

    [
      %{
        id: id,
        kind: "Field",
        order: 0,
        label: safe_label(label),
        var: var_name,
        placeholder: safe_label(ph)
      }
    ]
  end

  defp collect_controls_from_node(
         id,
         {"Button", [label | rest]} = btn_ast,
         _symbols,
         _ui_state,
         _visited
       ) do
    action_ast = List.first(rest)

    [
      %{
        id: id,
        kind: "Button",
        order: 1,
        label: safe_label(label),
        has_action?: action_ast != nil,
        ast: btn_ast
      }
    ]
  end

  defp collect_controls_from_node(id, {_comp, args}, symbols, ui_state, visited)
       when is_list(args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn {arg, idx} ->
      collect_controls_from_node("#{id}_#{idx}", arg, symbols, ui_state, visited)
    end)
  end

  defp collect_controls_from_node(id, list, symbols, ui_state, visited) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      collect_controls_from_node("#{id}_#{idx}", item, symbols, ui_state, visited)
    end)
  end

  defp collect_controls_from_node(_id, _other, _symbols, _ui_state, _visited), do: []

  defp extract_state_var({:var, v}), do: v
  defp extract_state_var({:ref, r}), do: "$" <> r
  defp extract_state_var("$" <> _ = s), do: s
  defp extract_state_var(s) when is_binary(s) and s != "", do: "$" <> s
  defp extract_state_var(_), do: "$input"

  defp resolve_select_options({:var, var_name}, symbols, ui_state) do
    val = Map.get(ui_state, var_name) || Map.get(symbols, var_name, [])
    if is_list(val), do: Enum.map(val, &safe_label/1), else: []
  end

  defp resolve_select_options({:ref, ref_name}, symbols, ui_state) do
    val = Map.get(ui_state, ref_name) || Map.get(symbols, ref_name, [])
    if is_list(val), do: Enum.map(val, &safe_label/1), else: []
  end

  defp resolve_select_options(list, _symbols, _ui_state) when is_list(list) do
    Enum.map(list, &safe_label/1)
  end

  defp resolve_select_options(_, _symbols, _ui_state), do: []

  defp execute_control_interaction(
         state,
         %{kind: "Select", label: label, var: var, options: opts},
         interaction,
         _opts
       ) do
    live_state = LiveSession.get_state(state.live_session)
    cur = to_string(Map.get(live_state.ui_state, var, List.first(opts) || ""))

    next_val =
      case interaction do
        {:set_val, explicit} ->
          to_string(explicit)

        dir when dir in [:prev_val, :left] and opts != [] ->
          idx = Enum.find_index(opts, &(&1 == cur)) || 0
          Enum.at(opts, rem(idx - 1 + length(opts), length(opts)))

        _ when opts != [] ->
          idx = Enum.find_index(opts, &(&1 == cur)) || 0
          Enum.at(opts, rem(idx + 1, length(opts)))

        _ ->
          cur
      end

    :ok = LiveSession.put_ui_state(state.live_session, var, next_val)
    updated_app = persist_ui_state(state.current_app, state.live_session)

    next_state = %{
      state
      | current_app: updated_app,
        status_message: "Updated Select \"#{label}\" (#{var}) ➔ #{next_val}"
    }

    {%{kind: "Select", var: var, value: next_val}, next_state}
  end

  defp execute_control_interaction(
         state,
         %{kind: "Toggle", label: label, var: var},
         interaction,
         _opts
       ) do
    live_state = LiveSession.get_state(state.live_session)
    cur = Map.get(live_state.ui_state, var, false) in [true, "true", 1]

    next_val =
      case interaction do
        {:set_val, explicit} -> explicit in [true, "true", 1]
        _ -> not cur
      end

    :ok = LiveSession.put_ui_state(state.live_session, var, next_val)
    updated_app = persist_ui_state(state.current_app, state.live_session)

    next_state = %{
      state
      | current_app: updated_app,
        status_message: "Toggled \"#{label}\" (#{var}) ➔ #{next_val}"
    }

    {%{kind: "Toggle", var: var, value: next_val}, next_state}
  end

  defp execute_control_interaction(
         state,
         %{kind: "Field", label: label, var: var},
         {:set_val, val},
         _opts
       ) do
    str_val = to_string(val)
    :ok = LiveSession.put_ui_state(state.live_session, var, str_val)
    updated_app = persist_ui_state(state.current_app, state.live_session)

    next_state = %{
      state
      | current_app: updated_app,
        status_message: "Set Field \"#{label}\" (#{var}) = #{inspect(str_val)}"
    }

    {%{kind: "Field", var: var, value: str_val}, next_state}
  end

  defp execute_control_interaction(state, %{kind: "Field", label: label, var: var}, _other, _opts) do
    {%{kind: "Field", var: var},
     %{state | status_message: "Use /set #{var} <value> to edit Field \"#{label}\""}}
  end

  defp execute_control_interaction(
         state,
         %{kind: "Button", id: id, label: label} = ctrl,
         _interaction,
         opts
       ) do
    dispatched =
      case LiveSession.dispatch_action(state.live_session, id) do
        {:ok, res} ->
          res

        {:error, :not_found} ->
          case Map.get(ctrl, :ast) do
            {"Button", [_lbl, action_ast | _]} ->
              live_state = LiveSession.get_state(state.live_session)
              merged = Map.merge(live_state.symbols, live_state.ui_state)
              OpenUITUI.Resolver.evaluate_expr(action_ast, merged)

            _ ->
              nil
          end
      end

    case extract_prompt_from_action(dispatched) do
      {:ok, prompt_str} ->
        dispatch_button_prompt(state, id, label, prompt_str, opts)

      :none ->
        {%{kind: "Button", id: id, dispatched: dispatched},
         %{state | status_message: "Triggered Button [#{label}]"}}
    end
  end

  defp extract_prompt_from_action({tag, [prompt_str | _]})
       when tag in ["ToAssistant", "@ToAssistant", "Action"] and is_binary(prompt_str) do
    {:ok, prompt_str}
  end

  defp extract_prompt_from_action({"Action", [[{tag, [prompt_str | _]} | _] | _]})
       when tag in ["ToAssistant", "@ToAssistant"] and is_binary(prompt_str) do
    {:ok, prompt_str}
  end

  defp extract_prompt_from_action({:to_assistant, prompt_str}) when is_binary(prompt_str) do
    {:ok, prompt_str}
  end

  defp extract_prompt_from_action(_), do: :none

  defp dispatch_button_prompt(state, id, label, prompt_str, opts) do
    app_with_action =
      state.current_app
      |> append_message("action", "Clicked [#{label}] ➔ \"#{prompt_str}\"", %{})
      |> Store.save_app!()

    state_with_action = %{
      state
      | current_app: app_with_action,
        status_message: "Triggered [#{label}]: #{prompt_str}"
    }

    if Keyword.get(opts, :send_to_llm, false) do
      case evolve_app_from_prompt(state_with_action, prompt_str, opts) do
        {:ok, evolved_state, turn_info} ->
          {%{kind: "Button", id: id, dispatched: prompt_str, evolved: turn_info}, evolved_state}

        {:error, _reason} ->
          {%{kind: "Button", id: id, dispatched: prompt_str}, state_with_action}
      end
    else
      {%{kind: "Button", id: id, dispatched: prompt_str}, state_with_action}
    end
  end

  defp persist_ui_state(app, live_session) do
    live_state = LiveSession.get_state(live_session)

    app
    |> Map.put("ui_state", live_state.ui_state)
    |> Store.save_app!()
  end

  defp append_message(app, role, text, meta) do
    msg = %{
      "role" => role,
      "text" => text,
      "timestamp" => Calendar.strftime(DateTime.utc_now(), "%H:%M:%S"),
      "meta" => meta
    }

    Map.update(app, "messages", [msg], &(&1 ++ [msg]))
  end

  defp drop_pending_messages(app) do
    Map.update(app, "messages", [], fn msgs ->
      Enum.reject(msgs, fn m -> get_in(m, ["meta", "pending"]) == true end)
    end)
  end

  defp summarize_components(code) when is_binary(code) do
    comps =
      Regex.scan(
        ~r/\b(Dashboard|Panel|Row|Stat|Sparkline|BarList|BarItem|Table|Col|Alert|Progress|Form|Field|Select|Toggle|Button)\s*\(/,
        code
      )
      |> Enum.map(fn [_, c] -> c end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.take(5)
      |> Enum.map_join(", ", fn {c, count} -> "#{count}× #{c}" end)

    if comps == "", do: "updated components", else: comps
  end

  defp extract_title(code, fallback) do
    case Regex.run(~r/root\s*=\s*(?:Dashboard|Panel)\(\s*"([^"]+)"/, code) do
      [_, title] -> title
      _ -> fallback || "OpenUI App"
    end
  end

  defp count_statements(code) when is_binary(code) do
    code
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> length()
  end

  defp safe_label(nil), do: ""
  defp safe_label(v) when is_binary(v), do: v
  defp safe_label(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp safe_label({:var, name}), do: name
  defp safe_label({:ref, name}), do: name
  defp safe_label(other), do: inspect(other)

  defp ensure_valid_root(merged_code, current_code, fallback_title, prompt) do
    syms = OpenUILang.parse_symbols(merged_code)

    cond do
      Map.has_key?(syms, "root") ->
        merged_code

      current_code != "" and Map.has_key?(OpenUILang.parse_symbols(current_code), "root") ->
        current_code

      true ->
        title = fallback_title || "Generated OpenUI App"
        clean_prompt = String.replace(prompt, "\"", "'")

        """
        root = Dashboard("#{title}", "Generated from prompt", [
          Alert("info", "#{clean_prompt}")
        ])
        """
    end
  end

  defp maybe_reload_disk_app(%{chat_in_flight?: true} = state), do: state

  defp maybe_reload_disk_app(state) do
    if rem(state.tick, 5) == 0 do
      hot_reload_modified_modules()
    end

    case state.current_app do
      %{"id" => app_id} = cur_app when is_binary(app_id) ->
        case Store.get_app(app_id) do
          {:ok, disk_app} ->
            if disk_app["updated_at"] != cur_app["updated_at"] or
                 disk_app["revision"] != cur_app["revision"] do
              load_app_into_session(state, disk_app)
            else
              state
            end

          _ ->
            state
        end

      _ ->
        state
    end
  end

  @doc """
  Purges and reloads any `.beam` modules that have been recompiled on disk so a
  long-running `mix openui.studio` process immediately picks up code updates.
  """
  @spec hot_reload_modified_modules() :: [module()]
  def hot_reload_modified_modules do
    modified = :code.modified_modules()

    Enum.each(modified, fn mod ->
      :code.purge(mod)
      :code.load_file(mod)
    end)

    modified
  end
end
