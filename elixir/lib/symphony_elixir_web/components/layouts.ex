defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:asset_version, StaticAssets.version())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src={"/vendor/phoenix_html/phoenix_html.js?v=#{@asset_version}"}></script>
        <script defer src={"/vendor/phoenix/phoenix.js?v=#{@asset_version}"}></script>
        <script defer src={"/vendor/phoenix_live_view/phoenix_live_view.js?v=#{@asset_version}"}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var root = document.documentElement;
            var liveSocket;
            var liveViewObserver;
            var connectPoll;
            var reconnectTimer;
            var csrfTokenMeta = document.querySelector("meta[name='csrf-token']");
            var csrfToken = csrfTokenMeta ? csrfTokenMeta.getAttribute("content") : null;

            var resolveStatusNode = function (id) {
              return document.getElementById(id);
            };

            var setBadgeVisibility = function (node, visible) {
              if (!node) return;

              node.hidden = !visible;
              node.setAttribute("aria-hidden", String(!visible));
              node.style.display = visible ? "inline-flex" : "none";
            };

            var setLiveViewStatus = function (connected) {
              root.classList.toggle("liveview-connected", connected);
              root.classList.toggle("liveview-disconnected", !connected);

              setBadgeVisibility(resolveStatusNode("liveview-status-live"), connected);
              setBadgeVisibility(resolveStatusNode("liveview-status-offline"), !connected);
            };

            var liveViewRootConnected = function () {
              var liveViewRoot = document.querySelector("[data-phx-main]");
              return Boolean(liveViewRoot && liveViewRoot.classList.contains("phx-connected"));
            };

            setLiveViewStatus(false);

            if (!window.Phoenix || !window.LiveView) return;

            liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            var syncLiveViewStatus = function () {
              var socketConnected = Boolean(liveSocket.isConnected && liveSocket.isConnected());
              setLiveViewStatus(socketConnected || liveViewRootConnected());

              if ((socketConnected || liveViewRootConnected()) && connectPoll) {
                window.clearInterval(connectPoll);
                connectPoll = null;
              }
            };

            var observeLiveViewRoot = function () {
              var liveViewRoot = document.querySelector("[data-phx-main]");

              if (!liveViewRoot) return;

              if (liveViewObserver) {
                liveViewObserver.disconnect();
              }

              liveViewObserver = new MutationObserver(syncLiveViewStatus);
              liveViewObserver.observe(liveViewRoot, {
                attributes: true,
                attributeFilter: ["class"]
              });
            };

            var scheduleReconnect = function (forceDisconnect) {
              if (!liveSocket) return;

              if (reconnectTimer) {
                window.clearTimeout(reconnectTimer);
              }

              reconnectTimer = window.setTimeout(function () {
                reconnectTimer = null;
                observeLiveViewRoot();

                if (forceDisconnect && liveSocket.disconnect) {
                  liveSocket.disconnect();
                }

                if (
                  !(
                    liveSocket.isConnected &&
                    liveSocket.isConnected() &&
                    liveViewRootConnected()
                  )
                ) {
                  liveSocket.connect();
                }

                syncLiveViewStatus();
              }, 150);
            };

            liveSocket.socket.onOpen(syncLiveViewStatus);
            liveSocket.socket.onClose(syncLiveViewStatus);
            liveSocket.socket.onError(syncLiveViewStatus);

            observeLiveViewRoot();
            liveSocket.connect();
            syncLiveViewStatus();
            window.liveSocket = liveSocket;

            connectPoll = window.setInterval(syncLiveViewStatus, 500);
            window.setTimeout(function () {
              if (!connectPoll) return;
              window.clearInterval(connectPoll);
              connectPoll = null;
              syncLiveViewStatus();
            }, 10000);

            window.addEventListener("pagehide", function (event) {
              if (event.persisted && liveSocket.disconnect) {
                liveSocket.disconnect();
              }
            });

            window.addEventListener("pageshow", function (event) {
              scheduleReconnect(Boolean(event.persisted));
            });

            window.addEventListener("focus", function () {
              if (!liveViewRootConnected()) {
                scheduleReconnect(false);
              }
            });

            window.addEventListener("online", function () {
              scheduleReconnect(false);
            });

            document.addEventListener("visibilitychange", function () {
              if (!document.hidden) {
                if (!liveViewRootConnected()) {
                  scheduleReconnect(false);
                }

                syncLiveViewStatus();
              }
            });
          });
        </script>
        <link rel="stylesheet" href={"/dashboard.css?v=#{@asset_version}"} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
