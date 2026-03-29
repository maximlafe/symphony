defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.{Endpoint, StaticAssets}

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    asset_version = StaticAssets.version()

    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:asset_version, asset_version)
      |> assign(:dashboard_css_path, asset_path("/dashboard.css", asset_version))
      |> assign(
        :phoenix_html_js_path,
        asset_path("/vendor/phoenix_html/phoenix_html.js", asset_version)
      )
      |> assign(:phoenix_js_path, asset_path("/vendor/phoenix/phoenix.js", asset_version))
      |> assign(
        :phoenix_live_view_js_path,
        asset_path("/vendor/phoenix_live_view/phoenix_live_view.js", asset_version)
      )
      |> assign(:live_socket_path, Endpoint.path("/live"))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src={@phoenix_html_js_path}></script>
        <script defer src={@phoenix_js_path}></script>
        <script defer src={@phoenix_live_view_js_path}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var root = document.documentElement;
            var liveSocket;
            var liveViewObserver;
            var localResetObserver;
            var connectPoll;
            var reconnectTimer;
            var csrfTokenMeta = document.querySelector("meta[name='csrf-token']");
            var csrfToken = csrfTokenMeta ? csrfTokenMeta.getAttribute("content") : null;
            var normalizeLocaleCandidate = function (value) {
              if (typeof value !== "string") return null;

              var trimmed = value.trim();

              if (!trimmed || trimmed === "undefined" || trimmed === "null") return null;

              return trimmed;
            };

            var appendCanonicalLocale = function (target, value) {
              var normalized = normalizeLocaleCandidate(value);

              if (!normalized) return;

              if (window.Intl && window.Intl.getCanonicalLocales) {
                try {
                  var canonical = window.Intl.getCanonicalLocales([normalized]);

                  if (canonical && canonical.length) {
                    target.push(canonical[0]);
                  }

                  return;
                } catch (_error) {
                  return;
                }
              }

              target.push(normalized);
            };

            var resolveLocalResetLocales = function () {
              var locales = [];
              var navigatorLanguages = window.navigator && window.navigator.languages;

              if (navigatorLanguages && navigatorLanguages.length) {
                Array.prototype.forEach.call(navigatorLanguages, function (value) {
                  appendCanonicalLocale(locales, value);
                });
              } else if (window.navigator && window.navigator.language) {
                appendCanonicalLocale(locales, window.navigator.language);
              }

              return locales.length ? locales : undefined;
            };

            var buildDateTimeFormatter = function (options) {
              if (!window.Intl || !window.Intl.DateTimeFormat) return null;

              var locales = resolveLocalResetLocales();

              try {
                return new window.Intl.DateTimeFormat(locales, options);
              } catch (_error) {
                try {
                  return new window.Intl.DateTimeFormat(undefined, options);
                } catch (_fallbackError) {
                  return null;
                }
              }
            };

            var localResetTimeFormatter = buildDateTimeFormatter({
              hour: "2-digit",
              minute: "2-digit",
              hour12: false
            });
            var localResetDateFormatter = buildDateTimeFormatter({
              day: "numeric",
              month: "long"
            });
            var localResetTitleFormatter = buildDateTimeFormatter({
              day: "numeric",
              month: "long",
              hour: "2-digit",
              minute: "2-digit",
              hour12: false
            });

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
                return "· " + localResetTimeFormatter.format(parsed);
              }

              return null;
            };

            var syncLocalResetLabels = function () {
              if (!localResetTimeFormatter && !localResetDateFormatter) return;

              document.querySelectorAll("[data-local-reset-at]").forEach(function (node) {
                var value = node.getAttribute("data-local-reset-at");
                var style = node.getAttribute("data-local-reset-style");
                var parsed = value ? new Date(value) : null;
                var text = formatLocalResetText(value, style);

                if (!parsed || Number.isNaN(parsed.getTime()) || !text) return;
                if (node.textContent !== text) node.textContent = text;

                if (localResetTitleFormatter) {
                  var title = localResetTitleFormatter.format(parsed);
                  if (node.getAttribute("title") !== title) node.setAttribute("title", title);
                }
              });
            };

            var queueLocalResetSync = function () {
              if (window.requestAnimationFrame) {
                window.requestAnimationFrame(syncLocalResetLabels);
              } else {
                window.setTimeout(syncLocalResetLabels, 0);
              }

              window.setTimeout(syncLocalResetLabels, 50);
              window.setTimeout(syncLocalResetLabels, 250);
            };

            var liveViewRootConnected = function () {
              var liveViewRoot = document.querySelector("[data-phx-main]");
              return Boolean(liveViewRoot && liveViewRoot.classList.contains("phx-connected"));
            };

            var liveSocketConnected = function () {
              return Boolean(liveSocket && liveSocket.isConnected && liveSocket.isConnected());
            };

            var liveViewReady = function () {
              return liveSocketConnected() || liveViewRootConnected();
            };

            var needsLiveViewReconnect = function () {
              return !liveSocketConnected() || !liveViewRootConnected();
            };

            setLiveViewStatus(false);
            queueLocalResetSync();

            if (!window.Phoenix || !window.LiveView) return;

            liveSocket = new window.LiveView.LiveSocket("<%= @live_socket_path %>", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            var syncLiveViewStatus = function () {
              setLiveViewStatus(liveViewReady());

              if (liveViewReady() && connectPoll) {
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

              if (!liveViewRoot) {
                queueLocalResetSync();
                return;
              }

              if (localResetObserver) {
                localResetObserver.disconnect();
              }

              localResetObserver = new MutationObserver(function () {
                queueLocalResetSync();
              });

              localResetObserver.observe(liveViewRoot, {
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true
              });

              queueLocalResetSync();
            };

            var scheduleReconnect = function () {
              if (!liveSocket) return;

              if (reconnectTimer) {
                window.clearTimeout(reconnectTimer);
              }

              reconnectTimer = window.setTimeout(function () {
                reconnectTimer = null;
                observeLiveViewRoot();
                observeLocalResetNodes();

                if (needsLiveViewReconnect()) {
                  liveSocket.connect();
                }

                syncLiveViewStatus();
                queueLocalResetSync();
              }, 150);
            };

            liveSocket.socket.onOpen(syncLiveViewStatus);
            liveSocket.socket.onClose(syncLiveViewStatus);
            liveSocket.socket.onError(syncLiveViewStatus);

            observeLiveViewRoot();
            observeLocalResetNodes();
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

            window.addEventListener("pageshow", function (event) {
              observeLiveViewRoot();
              observeLocalResetNodes();

              if (event.persisted) {
                syncLiveViewStatus();
                queueLocalResetSync();
                return;
              }

              if (needsLiveViewReconnect()) {
                scheduleReconnect();
              } else {
                syncLiveViewStatus();
                queueLocalResetSync();
              }
            });

            window.addEventListener("focus", function () {
              if (needsLiveViewReconnect()) {
                scheduleReconnect();
              } else {
                syncLiveViewStatus();
                queueLocalResetSync();
              }
            });

            window.addEventListener("online", function () {
              if (needsLiveViewReconnect()) {
                scheduleReconnect();
              } else {
                syncLiveViewStatus();
                queueLocalResetSync();
              }
            });

            document.addEventListener("visibilitychange", function () {
              if (!document.hidden) {
                if (needsLiveViewReconnect()) {
                  scheduleReconnect();
                } else {
                  syncLiveViewStatus();
                  queueLocalResetSync();
                }
              }
            });
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_path} />
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

  defp asset_path(path, version) when is_binary(path) and is_binary(version) do
    Endpoint.path(path) <> "?v=" <> version
  end
end
