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
            var localResetObserver;
            var connectPoll;
            var csrfTokenMeta = document.querySelector("meta[name='csrf-token']");
            var csrfToken = csrfTokenMeta ? csrfTokenMeta.getAttribute("content") : null;
            var localResetTimeFormatter = window.Intl && window.Intl.DateTimeFormat
              ? new window.Intl.DateTimeFormat("ru-RU", {
                  hour: "2-digit",
                  minute: "2-digit",
                  hour12: false
                })
              : null;
            var localResetDateFormatter = window.Intl && window.Intl.DateTimeFormat
              ? new window.Intl.DateTimeFormat("ru-RU", {
                  day: "numeric",
                  month: "long"
                })
              : null;
            var localResetTitleFormatter = window.Intl && window.Intl.DateTimeFormat
              ? new window.Intl.DateTimeFormat("ru-RU", {
                  day: "numeric",
                  month: "long",
                  hour: "2-digit",
                  minute: "2-digit",
                  hour12: false
                })
              : null;

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

            var formatLocalResetText = function (value, style) {
              var parsed = value ? new Date(value) : null;

              if (!parsed || Number.isNaN(parsed.getTime())) return null;

              if (style === "date" && localResetDateFormatter) {
                return "· " + localResetDateFormatter.format(parsed);
              }

              if (style === "time" && localResetTimeFormatter) {
                return "· в " + localResetTimeFormatter.format(parsed);
              }

              return null;
            };

            var syncLocalResetLabels = function () {
              if (!localResetTitleFormatter) return;

              document.querySelectorAll("[data-local-reset-at]").forEach(function (node) {
                var value = node.getAttribute("data-local-reset-at");
                var style = node.getAttribute("data-local-reset-style");
                var parsed = value ? new Date(value) : null;
                var text = formatLocalResetText(value, style);

                if (!parsed || Number.isNaN(parsed.getTime()) || !text) return;
                if (node.textContent !== text) node.textContent = text;

                var title = localResetTitleFormatter.format(parsed);
                if (node.getAttribute("title") !== title) node.setAttribute("title", title);
              });
            };

            var queueLocalResetSync = function () {
              window.requestAnimationFrame(syncLocalResetLabels);
              window.setTimeout(syncLocalResetLabels, 50);
              window.setTimeout(syncLocalResetLabels, 250);
            };

            var liveViewRootConnected = function () {
              var liveViewRoot = document.querySelector("[data-phx-main]");
              return Boolean(liveViewRoot && liveViewRoot.classList.contains("phx-connected"));
            };

            setLiveViewStatus(false);
            queueLocalResetSync();

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

            var observeLocalResetNodes = function () {
              var liveViewRoot = document.querySelector("[data-phx-main]");

              if (!liveViewRoot) return;

              if (localResetObserver) {
                localResetObserver.disconnect();
              }

              localResetObserver = new MutationObserver(function () {
                window.requestAnimationFrame(syncLocalResetLabels);
              });

              localResetObserver.observe(liveViewRoot, {
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true
              });

              queueLocalResetSync();
            };

            liveSocket.socket.onOpen(syncLiveViewStatus);
            liveSocket.socket.onClose(syncLiveViewStatus);
            liveSocket.socket.onError(syncLiveViewStatus);

            observeLiveViewRoot();
            observeLocalResetNodes();
            liveSocket.connect();
            syncLiveViewStatus();
            queueLocalResetSync();
            window.liveSocket = liveSocket;

            connectPoll = window.setInterval(syncLiveViewStatus, 500);
            window.setTimeout(function () {
              if (!connectPoll) return;
              window.clearInterval(connectPoll);
              connectPoll = null;
              syncLiveViewStatus();
            }, 10000);

            window.addEventListener("pageshow", function () {
              observeLiveViewRoot();
              observeLocalResetNodes();
              if (liveSocket.isConnected && !liveSocket.isConnected()) {
                liveSocket.connect();
              }
              syncLiveViewStatus();
              queueLocalResetSync();
            });

            document.addEventListener("visibilitychange", function () {
              if (!document.hidden) {
                syncLiveViewStatus();
                queueLocalResetSync();
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
