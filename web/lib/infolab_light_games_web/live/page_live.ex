defmodule InfolabLightGamesWeb.PageLive do
  use InfolabLightGamesWeb, :live_view
  require Logger

  @impl true
  def mount(_params, %{"remote_ip" => remote_ip} = _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(InfolabLightGames.PubSub, "coordinator:status")
      Phoenix.PubSub.subscribe(InfolabLightGames.PubSub, "bans")
    end

    {width, height} = Screen.dims()
    coordinator_status = Coordinator.status()

    socket =
      socket
      |> assign(game_id: nil, width: width, height: height)
      |> assign(coordinator_status: coordinator_status)
      |> assign(remote_ip: remote_ip)
      |> assign(banned: Bans.is_banned?(remote_ip))
      |> assign(animation_names: Coordinator.possible_idle_animations())
      |> assign(:scripts, [
        Routes.static_path(socket, "/assets/app.js")
      ])

    Logger.info("mounted #{inspect(self())}/#{inspect(remote_ip)} on main page")
    {:ok, _} = Presence.track_user(self(), remote_ip)

    {:ok, socket}
  end

  @impl true
  def handle_info({:banned, ip}, socket) do
    if socket.assigns.remote_ip == ip and socket.assigns.game_id do
      socket
      |> assign(banned: true)
      |> leave_game(ip, socket.assigns.remote_ip)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:coordinator_update, status}, socket) do
    {:noreply, assign(socket, coordinator_status: status)}
  end

  @impl true
  def handle_info({:game_win, id, winner}, socket) do
    {:noreply, put_flash(socket, :info, "Player '#{winner}' won the game: #{id}")}
  end

  @impl true
  def handle_info(
        {:game_terminated, id},
        %{assigns: %{game_id: id, remote_ip: remote_ip}} = socket
      ) do
    {:ok, _} = Presence.update_user_status(self(), remote_ip, "idle")
    {:noreply, assign(socket, game_id: nil)}
  end

  @impl true
  def handle_info({:game_terminated, _id}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("queue", _params, %{assigns: %{banned: true}} = socket) do
    {:noreply, put_flash(socket, :error, "You're banned mate")}
  end

  @impl true
  def handle_event(
        "queue",
        %{"game-name" => game_name},
        %{assigns: %{game_id: nil, remote_ip: remote_ip}} = socket
      ) do
    {:ok, game} =
      case game_name do
        "pong" -> {:ok, Games.Pong}
        "snake" -> {:ok, Games.Snake}
        _ -> {:error, :unknown_game}
      end

    id = Coordinator.queue_game(game, self())

    {:ok, _} = Presence.update_user_status(self(), remote_ip, "in game #{id}")

    socket =
      socket
      |> assign(game_id: id)
      |> put_flash(:info, "Joined game: #{id}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("queue", _params, socket) do
    # already in a game
    {:noreply, put_flash(socket, :error, "You're already in a game")}
  end

  @impl true
  def handle_event("queue-animation", _params, %{assigns: %{banned: true}} = socket) do
    {:noreply, put_flash(socket, :error, "You're banned mate")}
  end

  @impl true
  def handle_event(
        "queue-animation",
        %{"animation-name" => animation_name},
        socket
      ) do
    Logger.info("Queueing #{animation_name}")

    {module, {mode, name}} = Coordinator.idle_animation_for_name(animation_name)
    :ok = Coordinator.queue_idle_animation(module, mode, name)

    socket =
      socket
      |> put_flash(:info, "Queued #{name}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("join", _params, %{assigns: %{banned: true}} = socket) do
    {:noreply, put_flash(socket, :error, "You're banned mate")}
  end

  @impl true
  def handle_event(
        "join",
        %{"game-id" => id},
        %{assigns: %{game_id: nil, remote_ip: remote_ip}} = socket
      ) do
    Coordinator.join_game(id, self())

    {:ok, _} = Presence.update_user_status(self(), remote_ip, "in game #{id}")

    socket =
      socket
      |> assign(game_id: id)
      |> put_flash(:info, "Joined game: #{id}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("join", _params, socket) do
    # already in a game
    {:noreply, put_flash(socket, :error, "You're already in a game")}
  end

  @impl true
  def handle_event(
        "leave",
        %{"game-id" => id},
        %{assigns: %{game_id: id, remote_ip: remote_ip}} = socket
      ) do
    leave_game(socket, id, remote_ip)
  end

  @impl true
  def handle_event("leave", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("key_up", %{"key" => key}, socket) do
    Coordinator.route_input(self(), {false, key})

    {:noreply, socket}
  end

  @impl true
  def handle_event("key_down", %{"key" => key}, socket) do
    Coordinator.route_input(self(), {true, key})

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    Logger.warning("terminating user")
    :ok = Presence.untrack_user(self(), socket.assigns.remote_ip)

    unless is_nil(socket.assigns.game_id) do
      Coordinator.leave_game(socket.assigns.game_id, self())
    end
  end

  defp leave_game(socket, id, remote_ip) do
    Coordinator.leave_game(id, self())

    {:ok, _} = Presence.update_user_status(self(), remote_ip, "idle")

    socket =
      socket
      |> assign(game_id: nil)
      |> put_flash(:info, "Left game: #{id}")

    {:noreply, socket}
  end
end
